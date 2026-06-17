# Project Structure & Layering

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

## The pure domain core

Model the aggregate's lifecycle as data and a total function. The event-sourced shape — `decide` (command → events
or error) and `apply` (state + event → state) — is the worked example here and a strong default for anything with a
real state machine; a plain CRUD resource can instead expose a service function returning a validated row to persist.
Either way the rule holds: **the core is pure and exhaustively `match`ed, so adding a command is a compile error
until every site handles it.**

```rust
// src/domain/task.rs (excerpt) — no async, no I/O
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskState { Actionable, Delegated, Backlogged, Completed, Cancelled }

impl TaskState {
    pub fn is_terminal(self) -> bool { matches!(self, Self::Completed | Self::Cancelled) }
}

/// Commands against an existing aggregate, decided against folded current state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskCommand {
    Complete { completed_at: Option<DateTime<Utc>> },
    Cancel { cancelled_at: Option<DateTime<Utc>> },
    Delegate { delegated_to: String, /* … */ },
    // …
}

/// Validate a command, returning the events to append. Exhaustive over the
/// command enum: a new variant is a compile error here until handled.
pub fn decide(state: &Task, cmd: &TaskCommand, now: DateTime<Utc>)
    -> Result<Vec<TaskEvent>, DomainError>
{
    match cmd {
        TaskCommand::Complete { completed_at } => {
            ensure_not_terminal(state, "complete")?;             // a guard
            Ok(vec![TaskEvent::Completed { completed_at: completed_at.unwrap_or(now) }])
        }
        TaskCommand::Delegate { delegated_to, .. } => {
            ensure_not_terminal(state, "delegate")?;
            if delegated_to.is_empty() {
                return Err(DomainError::validation("delegatedTo", "delegatedTo is required"));
            }
            Ok(vec![TaskEvent::Delegated { delegated_to: delegated_to.clone(), /* … */ }])
        }
        // … every other command, exhaustively …
    }
}

/// Fold one event into state (pure). `None` only before the first event.
pub fn apply(state: Option<Task>, event: &DomainEvent<TaskEvent>) -> Task { /* … */ }
```

Why this matters for an agentic build: the invariants become unit tests with no fixtures or mocks (see
`testing.md`), and the exhaustiveness checker — not a reviewer — guarantees you handled every command/event when the
contract grows.

### Newtype IDs

Wrap identifiers so the task/project/event id spaces cannot be swapped, and so an id doubles as a sortable cursor.
Serialize transparently as the bare string the wire contract expects.

```rust
// src/ids.rs (shape) — generated via a small macro for each id type
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord,
         serde::Serialize, serde::Deserialize)]
pub struct TaskId(String);

impl TaskId {
    pub fn generate() -> Self { Self(format!("task_{}", ulid::Ulid::new())) }
    pub fn as_str(&self) -> &str { &self.0 }
}
impl std::fmt::Display for TaskId { /* write self.0 */ }
impl From<&str> for TaskId { fn from(v: &str) -> Self { Self(v.to_owned()) } }
```

For ids that double as a **global ordering cursor** (event ids backing SSE resume), a plain ULID only orders to the
millisecond; mint those from a process-global _monotonic_ generator so two ids minted in the same millisecond still
sort in creation order:

```rust
use std::sync::{LazyLock, Mutex};
use ulid::{Generator, MonotonicError, Ulid};

static EVENT_ULID: LazyLock<Mutex<Generator>> = LazyLock::new(|| Mutex::new(Generator::new()));

fn next_event_ulid() -> Ulid {
    let mut g = EVENT_ULID.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    g.generate().unwrap_or_else(|MonotonicError::Overflow| Ulid::new()) // overflow needs 2^80/ms
}
```

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
clock and auth disabled. No globals, no service locator.

## Inject the clock — never call `Utc::now()` in a handler

Time is a dependency. A `Clock` enum keeps production simple and tests deterministic:

```rust
#[derive(Clone, Copy)]
pub enum Clock { System, Fixed(DateTime<Utc>) }

impl Clock {
    pub fn now(self) -> DateTime<Utc> {
        match self { Self::System => Utc::now(), Self::Fixed(at) => at }
    }
}
```

Handlers read `state.clock.now()` and pass it into `decide`, so a test asserting `completedAt` defaults to "now" can
fix the clock and compare exactly. The same applies to randomness/ids where determinism matters.

## Module visibility

Keep the public surface smaller than the file tree. `http` submodules are private (`mod tasks;`), exposing only
`router`, `AppState`, and `AppError` from `http::mod`. Handlers are `pub(super)`; DTOs are `pub(super)`. The `domain`
and `store` public items are what `http` and tests need and no more. This lets the layout change without breaking
callers, and makes "what is the API of this layer" obvious.
