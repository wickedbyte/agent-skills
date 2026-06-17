# Observability & Deployment

The cross-cutting concerns that make an API operable: structured logs, health probes, and a small, secure container
image. (Typed env `Config` that fails fast at boot lives in `bootstrap-and-config.md`.)

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
  generic envelope (see `errors.md`).
- **Don't unit-test logging** — it isn't a behavioral contract.

## Health & readiness probes

**Two probes, two audiences.** `/readyz` answers "can I serve traffic right now?" for the load balancer and
readiness gate — a shallow dependency check (a `SELECT 1`-class ping), 200 or 503, and it stays **open**
(the balancer carries no token). `/healthz` answers "am I healthy?" with a richer report — component and
dependency status, build/version — meant for operators and dashboards. Because that detail leaks internal
topology, **`/healthz` sits behind authentication**, not in the always-open set. Keep `/openapi.json` open.
If an orchestrator needs a liveness check, point it at an open, bodyless `/livez` (or reuse `/readyz`) that
returns 200 — never expose the detailed `/healthz` publicly.

So there are three probe routes: open `/readyz` and `/livez` plus the gated `/healthz` (wired into the protected
router — see `routing-and-rpc.md`).

```rust
use axum::Json;
use serde_json::json;

// Open, bodyless liveness — the process is up. A failure tells the orchestrator to restart the pod.
async fn livez() -> StatusCode { StatusCode::OK }

// Open, shallow readiness — can we serve traffic? Ping the DB; 503 if not, so the load balancer
// stops routing here without restarting the pod.
async fn readyz(State(state): State<AppState>) -> StatusCode {
    match sqlx::query("SELECT 1").execute(state.store.pool()).await {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}

// Gated, detailed report — dependency status + build/version, for operators. Behind the auth gate
// because it exposes internal topology.
async fn healthz(State(state): State<AppState>) -> (StatusCode, Json<serde_json::Value>) {
    let db_ok = sqlx::query("SELECT 1").execute(state.store.pool()).await.is_ok();
    let status = if db_ok { StatusCode::OK } else { StatusCode::SERVICE_UNAVAILABLE };
    let body = json!({
        "status": if db_ok { "ok" } else { "degraded" },
        "version": env!("CARGO_PKG_VERSION"),
        "build": option_env!("GIT_SHA").unwrap_or("unknown"),
        "checks": { "database": if db_ok { "up" } else { "down" } },
    });
    (status, Json(body))
}
```

The open set is therefore **`/readyz`, `/livez`, `/openapi.json`**; `/healthz` and everything else sit behind the
auth gate.

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
(`lto`, `codegen-units = 1`, `strip`) is in `toolchain.md`.

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
