# Project Structure & Layering

This layout is the default for new work; adapt to an existing project's conventions rather than restructuring it.

The architecture is the thing this skill is most opinionated about, because it is what makes a Rust API testable,
compiler-checked, and cheap to extend. Two rules:

1. **Library crate + thin binary.** Everything lives in `lib.rs`; `main.rs` is bootstrap only. Tests link the
   library and drive the router and store directly — no subprocess, no socket.
2. **Layers depend inward.** `http → {domain, store}`; `store → domain`; `domain` depends on nothing in the crate
   and has **no `async`, no `axum`, no `sqlx`**. The pure core is where invariants live and where almost all the
   unit tests are.

## The lib/bin split

```rust
// src/lib.rs
#![forbid(unsafe_code)]

pub mod auth;
pub mod db;
pub mod domain;
pub mod http;
pub mod ids;
pub mod store;

pub use http::{router, AppState, Clock};
```

`main.rs` is bootstrap only — no business logic, no routes defined there. The tracing/pool/migrate/serve wiring,
typed env `Config`, and graceful shutdown live in `bootstrap-and-config.md`; the pure `decide`/`apply` core, newtype
IDs, and the injected `Clock` live in `domain-core.md`.

## `AppState` — shared, cheap to clone

Handlers receive dependencies through Axum's `State`. Everything in it must be cheap to clone (a pool handle, a
broadcast `Sender`, an `Arc`-wrapped gate), because Axum clones state per request.

```rust
// src/http/state.rs
#[derive(Clone)]
pub struct AppState {
    pub store: Store,                          // wraps a PgPool (Arc inside) — cheap clone
    pub clock: Clock,                          // Copy
    pub events: tokio::sync::broadcast::Sender<EventRecord>, // SSE fan-out
    pub auth: Auth,                            // Arc<Mode> inside — cheap clone
}

impl AppState {
    pub fn new(store: Store, clock: Clock) -> Self {
        Self::with_auth(store, clock, Auth::disabled())
    }
    pub fn with_auth(store: Store, clock: Clock, auth: Auth) -> Self {
        let (events, _) = tokio::sync::broadcast::channel(1024);
        Self { store, clock, events, auth }
    }
}
```

This is constructor-based dependency injection: `main` builds the real `AppState`; tests build one with a `Fixed`
clock and auth disabled. No globals, no service locator. (The `Clock` enum itself is in `domain-core.md`.)

## Module visibility

Keep the public surface smaller than the file tree. `http` submodules are private (`mod tasks;`), exposing only
`router`, `AppState`, and `AppError` from `http::mod`. Handlers are `pub(super)`; DTOs are `pub(super)`. The `domain`
and `store` public items are what `http` and tests need and no more. This lets the layout change without breaking
callers, and makes "what is the API of this layer" obvious.
