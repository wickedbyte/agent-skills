# Domain Core: the Pure Decision Layer

The `domain` layer is the pure core, and `domain` depends on nothing in the crate and has **no `async`, no `axum`, no
`sqlx`**. The pure core is where invariants live and where almost all the unit tests are.

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
