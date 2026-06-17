# Bootstrap & Configuration

The binary's job: read typed configuration from the environment, wire the real dependencies, and serve with a
graceful shutdown. Everything here lives in `main.rs` (bootstrap only; no business logic, no routes).

## The `main.rs` bootstrap

```rust
// src/main.rs — bootstrap only; no business logic, no routes defined here
#![forbid(unsafe_code)]

use std::net::SocketAddr;

use myapi::auth::{build_auth, AuthConfig};
use myapi::store::Store;
use myapi::{db, router, AppState, Clock};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() {
    init_tracing();

    let database_url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let pool = db::connect(&database_url).await.expect("connect to Postgres");
    db::run_migrations(&pool).await.expect("run migrations");

    let auth = build_auth(AuthConfig::from_env()).expect("auth init");
    let state = AppState::with_auth(Store::new(pool), Clock::System, auth);

    let port: u16 = std::env::var("PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8080);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = TcpListener::bind(addr).await.expect("bind listener");
    tracing::info!(%addr, "listening");
    axum::serve(listener, router(state)).await.expect("server error");
}
```

`expect` in `main` with a clear message is correct — a binary should fail loudly and immediately on a broken
environment. That license stops at `main`: the request path returns `Result`, never panics.

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

## Graceful shutdown

For clean rollouts, serve with a shutdown signal so in-flight requests drain:

```rust
axum::serve(listener, router(state))
    .with_graceful_shutdown(async {
        tokio::signal::ctrl_c().await.ok();
    })
    .await
    .expect("server error");
```
