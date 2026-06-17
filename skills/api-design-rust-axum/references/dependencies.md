# Dependencies, `Cargo.toml`, Lints & Toolchain

The crate _names and roles_ here are durable; the _versions_ are not. Always add and bump with `cargo`, which reads
the live registry, and verify the API on docs.rs for the resolved version — the web stack churns (Axum/Tokio/Tower
co-evolve, and `sqlx` 0.9 / `jsonwebtoken` 10 landed after these examples were written).

## Resolving current versions

```bash
cargo add axum tokio --features tokio/full
cargo add serde --features derive
cargo add serde_json thiserror chrono --features chrono/serde
cargo add sqlx --no-default-features \
  --features runtime-tokio,postgres,macros,migrate,chrono,json
cargo add tower-http --features trace
cargo add --dev tower --features util
cargo add --dev http-body-util
cargo update            # deliberate, reviewed; commit Cargo.lock
cargo audit             # cargo install cargo-audit — check advisories before shipping
```

`cargo add` writes a caret requirement (e.g. `axum = "0.8"`) and resolves the newest compatible release into
`Cargo.lock`. **Commit `Cargo.lock`** for a binary — it pins the exact build. The caret in `Cargo.toml` keeps the
manifest readable; the lockfile is the source of truth.

## What each crate is for

- **`axum`** — the HTTP framework: routing, extractors, `IntoResponse`, SSE. Built on `tower`/`hyper`, so the whole
  `tower`/`tower-http` middleware ecosystem (tracing, CORS, compression, timeouts, request-body limits) is available.
- **`tokio`** — the async runtime. Use `features = ["full"]` in the **binary**; keep the runtime choice out of any
  reusable library layer (see `project-structure.md`).
- **`tower-http`** — drop-in middleware layers (`TraceLayer`, `CorsLayer`, `TimeoutLayer`, `RequestBodyLimitLayer`,
  `CompressionLayer`). Prefer these over hand-rolled middleware.
- **`serde` + `serde_json`** — (de)serialization. Every DTO derives `Serialize`/`Deserialize`.
- **`sqlx`** — async, compile-time-checked SQL. Default features pull a TLS backend; if the DB link is in-cluster
  with TLS off, use `default-features = false` and select only what you need to avoid building `ring`/`openssl`.
- **`thiserror`** — typed error enums for the `domain` and `store` layers. `anyhow` is fine in `main.rs` bootstrap,
  never on the request path (the request path returns typed errors that map to the wire envelope).
- **`chrono`** — `DateTime<Utc>` for timestamps and `NaiveDate` for date-only fields; `features = ["serde"]` for
  serde support. (Keep date-only and timestamp as distinct types — a frequent contract bug otherwise.)
- **`tracing` + `tracing-subscriber`** — structured logging (`json`, `env-filter`). See
  `observability-deployment.md`.
- **`jsonwebtoken`** — JWT validation for OIDC resource-server auth. See `auth-oauth2.md`.
- **`ulid`** (or **`uuid`**) — sortable identifiers wrapped in newtypes (see `project-structure.md`).
- **Dev-deps** `tower` (`util`) + `http-body-util` — drive the router in-process in tests via `oneshot` and collect
  response bodies. See `testing.md`.

### Validation: prefer the core, reach for a crate only when it pays

For most APIs, field validation belongs in the `decide`/service function as plain Rust (`if title.is_empty()`), so a
rejection produces a typed `DomainError` with the offending field name — which the error boundary maps to a 422
carrying `details.field`. Pull in **`garde`** or **`validator`** only when the contract has a large, declarative
rule set (lengths, regex, ranges across many fields) that is tedious to hand-write; even then, keep the derived
checks on the DTO and the cross-field/business rules in the core.

## A representative `Cargo.toml`

```toml
[package]
name = "myapi"
version = "0.1.0"
edition = "2024"
rust-version = "1.96"        # real MSRV floor; bump deliberately
publish = false

[[bin]]
name = "myapi"
path = "src/main.rs"

[dependencies]
# Versions shown are illustrative — `cargo add` resolves the current release.
axum = "0.8"
tokio = { version = "1", features = ["full"] }
tower-http = { version = "0.6", features = ["trace"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "2"
chrono = { version = "0.4", features = ["serde"] }
ulid = "1"
jsonwebtoken = "9"
# No default features → no bundled TLS backend; add a tls feature if you need it.
sqlx = { version = "0.8", default-features = false, features = [
    "runtime-tokio", "postgres", "macros", "migrate", "chrono", "json",
] }

[dev-dependencies]
tower = { version = "0.5", features = ["util"] }   # ServiceExt::oneshot
http-body-util = "0.1"                              # collect response bodies

[lints.rust]
unsafe_code = "forbid"

[lints.clippy]
# Pedantic as a warning surface; CI runs clippy -D warnings, so anything that
# fires must be fixed or #[allow]-ed with a `reason`.
pedantic = { level = "warn", priority = -1 }
# An application binary, not a published library: silence the doc-ceremony lints.
missing_errors_doc = "allow"
missing_panics_doc = "allow"
must_use_candidate = "allow"
module_name_repetitions = "allow"

[profile.release]
lto = true
codegen-units = 1
strip = true
```

The `[lints]` table (Cargo 1.74+) keeps lint config in the manifest instead of crate-root `#![deny(...)]` attributes
and applies it across all targets. `unsafe_code = "forbid"` is appropriate for a web service — there is no reason to
reach for `unsafe` in this domain, and forbidding it crate-wide makes that a compile error rather than a review note.

## Toolchain & formatter pinning

Pin the toolchain so local, CI, and Docker builds agree:

```toml
# rust-toolchain.toml
[toolchain]
channel = "1.96.0"                      # keep in step with Cargo.toml rust-version
components = ["rustfmt", "clippy"]
```

```toml
# rustfmt.toml — stable options only
edition = "2024"
```

## Feature-flag discipline

- Select `sqlx` features narrowly. `default-features = false` plus an explicit list avoids compiling a TLS stack you
  do not use; add a `tls-rustls`/`tls-native-tls` feature only when the DB connection actually needs TLS.
- `tokio = ["full"]` is fine for a binary; a library should request only the runtime features it uses.
- Keep dev-only crates (`tower`, `http-body-util`) in `[dev-dependencies]` so they never ship in the release binary.

## The gate

Every change passes, in order:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo sqlx prepare --check -- --all-targets   # offline metadata fresh & complete
cargo test                                     # then cargo test --doc
```

Wire these into a `Makefile` (`make gate`) and CI so the same sequence runs everywhere. `clippy -D warnings` and the
`sqlx` offline check are the two highest-signal gates for an agentic build — they catch contract/schema drift the
moment it is introduced.
