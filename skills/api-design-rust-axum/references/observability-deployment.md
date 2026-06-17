# Observability, Config & Deployment

The cross-cutting concerns that make an API operable: structured logs, health probes, typed configuration, and a
small, secure container image.

## Structured logging with `tracing`

Use `tracing` for spans and events and `tracing-subscriber` to emit **JSON to stdout**, with the level controlled by
`RUST_LOG`. Initialize once in `main`:

```rust
use tracing_subscriber::EnvFilter;

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt().json().with_env_filter(filter).init();
}
```

Add request-level spans with `tower_http::trace::TraceLayer` at the router root (see `routing-and-rpc.md`) — you get
per-request method/path/status/latency for free. Use structured fields, not string interpolation, so logs stay
queryable:

```rust
tracing::info!(%addr, "listening");
tracing::error!(error = %err, task_id = %id, "unhandled store error");
```

Rules:

- **Never log secrets or tokens.** Don't log `Authorization` headers, JWTs, or full request bodies that may carry
  PII. Log ids and outcomes, not credentials.
- **Log the cause of a 500, expose nothing.** The `Internal` error path logs `error = %cause` and returns the
  generic envelope (see `error-handling.md`).
- **Don't unit-test logging** — it isn't a behavioral contract.

## Health & readiness probes

Two distinct endpoints, both always open (no auth):

- **`/healthz` (liveness)** — the process is up. Return 200 unconditionally; a failure here tells an orchestrator to
  restart the pod.
- **`/readyz` (readiness)** — the process can serve traffic, i.e. dependencies are reachable. Check the DB; 503 if
  not. A failure here tells the load balancer to stop routing, without restarting.

```rust
async fn healthz() -> StatusCode { StatusCode::OK }

async fn readyz(State(state): State<AppState>) -> StatusCode {
    match sqlx::query("SELECT 1").execute(state.store.pool()).await {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}
```

Keep `/openapi.json` open too. Everything else sits behind the auth gate.

## Typed configuration from the environment

Read config from env into a typed struct **at boot**, and fail fast with a clear message if something required is
missing or malformed — a misconfigured service should refuse to start, not 500 later.

```rust
pub struct Config {
    pub database_url: String,
    pub port: u16,
}

impl Config {
    pub fn from_env() -> Self {
        let database_url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
        let port = std::env::var("PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8080);
        Self { database_url, port }
    }
}
```

`expect` in `main`/config is the right tool: a clear panic at startup beats a service that boots into a broken state.
This is the one place the request-path "never panic" rule does not apply. (For larger config surfaces, `serde` +
`envy`, or `figment`, deserialize env into the struct with validation.)

## The production Dockerfile (multi-stage, distroless)

Build with the pinned toolchain image, run on a minimal non-root base. Two tricks: build with `SQLX_OFFLINE=true`
against the committed `.sqlx` cache (no DB at build time), and warm the dependency layer so source-only edits don't
recompile the whole graph.

```dockerfile
# syntax=docker/dockerfile:1

# ---- build stage ----
FROM rust:1.96-slim-bookworm AS build
WORKDIR /src
ENV SQLX_OFFLINE=true                 # compile-time query checks read the committed .sqlx cache

# Warm the dependency layer against a throwaway main.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs && cargo build --release && rm -rf src

# Real build.
COPY . .
RUN touch src/main.rs && cargo build --release && \
    mkdir -p /out && cp target/release/myapi /out/myapi

# ---- runtime stage ----
# distroless/cc carries glibc + libgcc for the default gnu target — no musl build needed; nonroot.
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /out/myapi /myapi
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/myapi"]
```

Match the runtime base to the build target: a glibc build (`*-unknown-linux-gnu`, the default) runs on
`distroless/cc`; a fully static `*-musl` build can run on `distroless/static` or `scratch`. The release profile
(`lto`, `codegen-units = 1`, `strip`) is in `dependencies.md`.

## `compose.yaml` for local + CI

Ship a compose file so the service runs with its own datastore in one command — independent and parallelizable.

```yaml
services:
    postgres:
        image: postgres:17
        environment:
            POSTGRES_USER: app
            POSTGRES_PASSWORD: app
            POSTGRES_DB: app
        healthcheck:
            test: ["CMD-SHELL", "pg_isready -U app"]
            interval: 2s
            timeout: 3s
            retries: 30
    api:
        build: .
        environment:
            DATABASE_URL: postgres://app:app@postgres:5432/app?sslmode=disable
            PORT: "8080"
            RUST_LOG: info
        ports: ["8080:8080"]
        depends_on:
            postgres:
                condition: service_healthy
```

`depends_on … service_healthy` ensures the API starts only after Postgres is accepting connections, so boot-time
migrations succeed. Add a `valkey`/`redis` service the same way if the API uses a cache or distributed lock.
