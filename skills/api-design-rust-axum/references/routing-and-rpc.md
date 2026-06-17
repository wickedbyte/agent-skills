# Routing, Extractors & Resource-Action RPC

## Assembling the router

Build the router in one function over `AppState`. Separate the always-open meta endpoints from the
auth-gated application routes by composing two routers and merging them, so the auth middleware applies to exactly
the protected set.

```rust
// src/http/mod.rs
use axum::routing::{get, patch, post};
use axum::middleware::from_fn_with_state;
use axum::Router;

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route("/tasks", post(tasks::create_task).get(tasks::list_tasks))
        .route(
            "/tasks/{taskId}",
            get(tasks::get_task)
                .patch(tasks::patch_task)
                .post(commands::dispatch_command), // RPC colon-commands — see below
        )
        .route("/projects", post(projects::create).get(projects::list))
        .route("/projects/{projectId}", patch(projects::patch).post(projects::dispatch_command))
        .route("/views/today", get(views::today))
        .route("/events", get(sse::stream_events))
        .route_layer(from_fn_with_state(state.clone(), require_auth));

    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/openapi.json", get(openapi_doc))
        .merge(protected)
        .with_state(state)
}
```

Notes:

- **Axum 0.8 path syntax** is `{param}` (braces), not the old `:param`. Wildcards are `{*rest}`. This matters: the
  colon is now free to appear as a literal in a segment, which is what makes the RPC pattern below tractable — but
  see the capture caveat.
- `.route_layer` applies middleware only to routes already added to that router (the protected set), so meta
  endpoints stay open. `from_fn_with_state` gives the middleware access to `AppState` (for the auth gate).
- `with_state` is applied once at the end, after `merge`, so both sub-routers share the same state type.

## Extractors and their order

Extractors run in the order declared. Body-consuming extractors (`Bytes`, `Json`, `String`) must come **last** —
only one may consume the body. A typical handler:

```rust
pub(super) async fn create_task(
    State(state): State<AppState>,   // shared deps
    body: Bytes,                     // raw body LAST — we parse it ourselves
) -> Result<(StatusCode, Json<TaskEnvelope>), AppError> {
    let request: CreateTaskRequest = parse_body(&body)?;   // → 422 on bad JSON (see request-and-response.md)
    let command = request.into_command();
    let now = state.clock.now();
    let events = decide_capture(&command)?;                // domain
    let id = TaskId::generate();
    let task = state.store.commit_task(&id, None, events, now).await?; // store
    Ok((StatusCode::CREATED, Json(TaskEnvelope::from(task))))
}
```

Why take `Bytes` rather than `Json<T>`: the built-in `Json` extractor returns Axum's own plain-text 422 on a parse
failure, which does **not** match your error envelope. Taking `Bytes` and parsing yourself routes every failure
through `AppError` (see `error-handling.md` / `request-and-response.md`). The handler body reads as
**parse → delegate (domain) → persist (store) → map**, with `?` carrying each failure to the one boundary.

### Path and query

```rust
use axum::extract::{Path, Query};

// Single path param:
async fn get_task(State(state): State<AppState>, Path(task_id): Path<String>) -> Result<…> { … }

// Tolerant query parsing — a malformed query string becomes "no filters", because the
// endpoint only documents a 200. Don't 400 on something the contract says always succeeds.
async fn list_tasks(
    State(state): State<AppState>,
    params: Result<Query<HashMap<String, String>>, QueryRejection>,
) -> Result<Json<TaskListEnvelope>, AppError> {
    let params = params.map(|Query(p)| p).unwrap_or_default();
    let tasks = state.store.list_tasks(&list_filter(&params)).await?;
    Ok(Json(TaskListEnvelope::from_tasks(&tasks)))
}
```

For richer query contracts, deserialize into a typed struct with `Query<MyParams>` and `#[serde(default)]` fields;
choose the `HashMap` form only when filters are open-ended and a parse failure must be lenient.

## Resource-action RPC: `POST /tasks/{taskId}:complete`

A literal `:` immediately after a `{param}` capture is fragile in `matchit` (the router behind Axum): depending on
version the capture may swallow the suffix or fail to match. The robust, version-independent pattern is
**capture-and-dispatch**:

- Register one route, `POST /tasks/{taskId}`, that captures the **whole** final segment (colon suffix included).
- Split it on the last `:` into `(id, command)` and `match` the command name.
- 404 unknown commands and no-colon paths. REST `GET`/`PATCH` on the same `/tasks/{taskId}` route coexist, because
  a REST id never contains a colon (spec pattern `^[^:]+$`).

```rust
// src/http/commands.rs
pub(super) async fn dispatch_command(
    State(state): State<AppState>,
    Path(raw): Path<String>,   // e.g. "task_01J…:complete"
    body: Bytes,
) -> Result<Json<TaskEnvelope>, AppError> {
    let (id_str, command) = split_command(&raw).ok_or_else(|| AppError::not_found("task"))?;
    let id = TaskId::from(id_str);

    let base = state.store.load_task(&id).await?
        .ok_or_else(|| AppError::not_found("task"))?;
    let cmd = build_command(command, &body, &state).await?;   // parse per-command body
    let now = state.clock.now();
    let events = decide(&base, &cmd, now)?;
    let task = state.store.commit_task(&id, Some(base), events, now).await?;
    Ok(Json(TaskEnvelope::from(task)))
}

/// Split on the single trailing `:`; `None` for a plain id or an empty side.
pub(super) fn split_command(raw: &str) -> Option<(&str, &str)> {
    let (id, command) = raw.rsplit_once(':')?;
    (!id.is_empty() && !command.is_empty()).then_some((id, command))
}

async fn build_command(command: &str, body: &Bytes, state: &AppState)
    -> Result<TaskCommand, AppError>
{
    let cmd = match command {
        "complete" => {
            let req: CompleteTaskRequest = parse_optional_body(body)?; // body optional → {}
            TaskCommand::Complete { completed_at: req.completed_at }
        }
        "delegate" => {
            let req: DelegateTaskRequest = parse_optional_body(body)?;
            TaskCommand::Delegate { delegated_to: req.delegated_to.unwrap_or_default(), /* … */ }
        }
        "assignProjects" => {
            let req: AssignProjectsRequest = parse_body(body)?;  // body required here
            TaskCommand::AssignProjects { project_ids: req.project_ids }
        }
        _ => return Err(AppError::not_found("task")),            // unknown command → 404
    };
    Ok(cmd)
}
```

**Always unit-test the split** — it is the one piece of routing logic that can silently mis-parse:

```rust
#[test]
fn splits_id_and_command_on_the_colon() {
    assert_eq!(split_command("task_01J9Z7:complete"), Some(("task_01J9Z7", "complete")));
}
#[test]
fn plain_id_is_not_mis_split() { assert_eq!(split_command("task_01J9Z7"), None); }
#[test]
fn empty_sides_are_rejected() {
    assert_eq!(split_command(":complete"), None);
    assert_eq!(split_command("task_01J9Z7:"), None);
}
```

Also guard the **REST** handlers against a colon leaking in (so `GET /tasks/{id}` can't be hit with a command
suffix): reject any `{taskId}` containing `:` as a 404 before using it.

The alternative — registering each literal command route (`/tasks/{taskId}:complete`, …) — is viable only if your
router version reliably matches a literal colon after a capture; if you choose it, prove it with a test. Default to
capture-and-dispatch: one handler, central command parsing, no router-version risk.

## Cross-cutting middleware

Prefer `tower-http` layers over hand-rolled middleware, added at the router root:

```rust
use tower_http::trace::TraceLayer;
use tower_http::timeout::TimeoutLayer;
use tower_http::limit::RequestBodyLimitLayer;
use std::time::Duration;

Router::new()
    // … routes …
    .layer(TraceLayer::new_for_http())                  // structured request spans
    .layer(TimeoutLayer::new(Duration::from_secs(30)))  // bound slow handlers
    .layer(RequestBodyLimitLayer::new(1024 * 1024))     // reject oversized bodies
```

`.layer` wraps the whole router (outermost first); `.route_layer` scopes to specific routes (as with auth above).
Order matters: put tracing outermost so it records everything, including rejections from inner layers.

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
