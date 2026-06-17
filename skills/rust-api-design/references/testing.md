# Testing an API in Rust

The layering pays off here: most logic is in a pure core that needs no runtime or database, so most tests are plain,
fast `#[test]`s. Above that sit in-process HTTP tests and a thin layer of full-stack conformance.

```
        Schemathesis / SSE conformance   ← few, against the running container (slow)
        oneshot HTTP tests (#[sqlx::test]) ← per documented operation (medium)
        pure-core unit tests (#[test])     ← per invariant (many, fast)  ← write these first
```

## 1. Pure-core unit tests — the bulk

`decide`/`apply`/slug/merge logic is pure, so its tests are direct: call the function, assert the result. No mocks,
no async, no fixtures. **TDD works naturally**: turn each invariant in the contract into a failing test, then write
the code to pass it. Name tests after the invariant so the suite is a checklist.

```rust
#[test]
fn complete_defaults_completed_at_to_now() {
    let evs = decide(&actionable_task(), &TaskCommand::Complete { completed_at: None }, ts()).unwrap();
    assert_eq!(evs, vec![TaskEvent::Completed { completed_at: ts() }]);  // fixed clock → exact assert
}

#[test]
fn lifecycle_commands_rejected_from_terminal() {
    let mut completed = actionable_task();
    completed.state = TaskState::Completed;
    let err = decide(&completed, &TaskCommand::Backlog, ts()).unwrap_err();
    assert!(matches!(err, DomainError::InvalidStateTransition { .. }));
}
```

A fixed timestamp helper (`ts()`) makes "defaults to now" assertions exact — the value comes from the injected clock,
not the wall clock. Also unit-test the pieces of routing/parsing that can silently misbehave: the `{id}:command`
split, slug generation/dedup, the date-merge resolver, and event (de)serialization round-trips.

```rust
#[test]
fn event_round_trips_through_jsonb() {
    let event = TaskEvent::Completed { completed_at: ts() };
    let (type_, data) = encode_task(&event).unwrap();
    assert_eq!(data["type"], type_, "stored jsonb is self-describing");
    assert_eq!(decode_task(data).unwrap(), event);
}
```

## 2. In-process HTTP tests with `oneshot`

Drive the real router without a socket via `tower::ServiceExt::oneshot`, and get an isolated, migrated database per
test from `#[sqlx::test]`. This exercises routing, extraction, parsing, the error envelope, and persistence together
— the whole edge — in milliseconds.

```rust
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use sqlx::PgPool;
use tower::ServiceExt;

fn app(pool: PgPool) -> Router {
    router(AppState::new(Store::new(pool), Clock::Fixed(ts())))   // fixed clock → deterministic
}

/// Send a request, return (status, parsed-JSON-or-Null).
async fn send(app: &Router, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
    let builder = Request::builder().method(method).uri(uri);
    let request = match body {
        Some(b) => builder.header("content-type", "application/json").body(Body::from(b.to_string())).unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    };
    let res = app.clone().oneshot(request).await.unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let value = if bytes.is_empty() { Value::Null } else { serde_json::from_slice(&bytes).unwrap() };
    (status, value)
}

#[sqlx::test]
async fn create_requires_title(pool: PgPool) {
    let app = app(pool);
    let (status, body) = send(&app, "POST", "/tasks", Some(json!({"title": ""}))).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["code"], "validation_failed");
}

#[sqlx::test]
async fn create_unknown_project_is_422_not_404(pool: PgPool) {
    let app = app(pool);
    let (status, body) = send(&app, "POST", "/tasks",
        Some(json!({"title": "t", "projectIds": ["project_missing"]}))).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["error"]["details"]["field"], "projectIds");   // exact envelope shape
}
```

`#[sqlx::test]` (with the `migrate` feature and a `DATABASE_URL` to a test server) creates a fresh database, runs
`migrations/`, hands you a `PgPool`, and drops it after — so tests are isolated and parallel-safe. Assert the exact
error envelope (`code`, `details.field`) and the success shape (the strict mirror struct from
`openapi-contract.md`), so a contract regression fails a test.

## 3. Property-style test: replay reproduces projections

For an event-sourced store, the projection must be a pure function of the log. Assert it: after a sequence of
commands, `rebuild()` (truncate + replay) must reproduce the same projection rows. This catches any drift between the
write path and the fold.

```rust
#[sqlx::test]
async fn replay_reproduces_projections(pool: PgPool) {
    let store = Store::new(pool);
    // … apply a varied sequence of commands …
    let before = store.list_tasks(&Default::default()).await.unwrap();
    store.rebuild().await.unwrap();           // discard projections, replay events
    let after = store.list_tasks(&Default::default()).await.unwrap();
    assert_eq!(before, after);
}
```

## 4. Auth tests

Build the authenticator from a locally-minted key so no network is involved (see `auth-oauth2.md`): mint a JWT with a
test RSA key, feed the matching JWKS into `Authenticator::from_jwks`, and assert valid → 200, missing/expired/wrong-
`kid`/wrong-`aud` → 401, insufficient scope → 403, and that meta routes are reachable with no token.

## 5. SSE tests

Subscribe to `/events`, perform a mutation, and assert the emitted frame's `id:`/`event:`/`data:`. Then reconnect
with a `Last-Event-ID` header and assert only strictly-later events arrive (the resume contract). Read frames from
the streaming body with a bounded timeout so a hang fails fast rather than blocking the suite.

## 6. Full-stack conformance: Schemathesis

The static tests above run in `cargo test`. The final gate fuzzes the **running container** against the OpenAPI spec
(`st run ./openapi.yaml --url … --checks all`) — see `openapi-contract.md`. A green unit/integration suite plus a
clean Schemathesis run is the bar for "contract-correct".

## The mechanical gate

Wire every check into one command so the same sequence runs locally and in CI:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo sqlx prepare --check -- --all-targets
cargo test          # unit + #[sqlx::test] integration
cargo test --doc    # doctests on public items
```

Notes:

- **Don't unit-test logging.** Tracing output is not a behavioral contract; asserting on log lines is brittle.
- Prefer `cargo nextest run` for faster, cleaner parallel runs once the suite grows (doctests still need
  `cargo test --doc`).
- Keep `oneshot` helpers (`app`, `send`, `assert_*_shape`) in one place per test file so each test reads as
  arrange → act → assert against the envelope.
