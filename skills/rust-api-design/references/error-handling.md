# Errors → the HTTP Boundary

There must be **exactly one** place that turns a failure into an HTTP status and body: an `AppError` enum with
`impl IntoResponse`. Layers below produce typed errors (`DomainError`, `StoreError`); `From` conversions lift them
into `AppError`; handlers return `Result<_, AppError>` and propagate with `?`. No handler ever builds a
`(StatusCode, Json)` tuple for an error path.

## Typed errors per layer

The pure core and the store each expose a `thiserror` enum describing _what went wrong_, not _which HTTP status_ —
that mapping is the edge's job.

```rust
// src/domain/error.rs
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DomainError {
    #[error("validation failed: {field}: {reason}")]
    Validation { field: String, reason: String },
    #[error("invalid state transition: cannot {command} a {from} task")]
    InvalidStateTransition { from: TaskState, command: String },
}
```

```rust
// src/store/error.rs
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("optimistic concurrency conflict: stream version is stale")]
    VersionConflict,                              // → 409
    #[error("project slug already exists")]
    SlugConflict,                                 // → 409
    #[error("event codec error: {0}")]
    Codec(#[from] serde_json::Error),             // → 500
    #[error(transparent)]
    Database(#[from] sqlx::Error),                // → 500
}
```

`#[from]` gives free `?` conversion (`serde_json::Error`/`sqlx::Error` → `StoreError`); `#[error(transparent)]`
forwards the source's `Display`. Note the deliberate split: `VersionConflict`/`SlugConflict` are *expected* outcomes
the edge maps to 409; everything else is an internal 500 whose cause is logged, not exposed.

## The single edge enum

`AppError` carries exactly what the wire envelope needs and nothing more.

```rust
// src/http/error.rs
pub enum AppError {
    Validation { field: Option<String>, reason: String }, // 422 validation_failed (+ details.field)
    Unauthorized { message: String },                     // 401 unauthorized (+ WWW-Authenticate)
    NotFound { resource: String },                        // 404 not_found
    Conflict { message: String },                         // 409 conflict
    InvalidStateTransition { message: String },           // 409 invalid_state_transition
    Internal,                                              // 500 internal_error (cause logged only)
}

impl AppError {
    pub fn validation(reason: impl Into<String>) -> Self {
        Self::Validation { field: None, reason: reason.into() }
    }
    pub fn validation_field(field: impl Into<String>, reason: impl Into<String>) -> Self {
        Self::Validation { field: Some(field.into()), reason: reason.into() }
    }
    pub fn not_found(resource: impl Into<String>) -> Self {
        Self::NotFound { resource: resource.into() }
    }
    pub fn unauthorized(message: impl Into<String>) -> Self {
        Self::Unauthorized { message: message.into() }
    }
}
```

## `IntoResponse`: the one status map

Render the stable envelope here. This is the only function in the codebase that chooses a status code.

```rust
use axum::{Json, response::{IntoResponse, Response}};
use axum::http::{HeaderValue, StatusCode, header};
use serde_json::{json, Map, Value};

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let challenge = matches!(self, Self::Unauthorized { .. });
        let (status, code, message, details): (StatusCode, &str, String, Option<Value>) = match self {
            Self::Unauthorized { message } =>
                (StatusCode::UNAUTHORIZED, "unauthorized", message, None),
            Self::Validation { field, reason } => {
                let details = field.map(|f| json!({ "field": f, "reason": reason.clone() }));
                (StatusCode::UNPROCESSABLE_ENTITY, "validation_failed", reason, details)
            }
            Self::NotFound { resource } =>
                (StatusCode::NOT_FOUND, "not_found", format!("{resource} not found"), None),
            Self::Conflict { message } =>
                (StatusCode::CONFLICT, "conflict", message, None),
            Self::InvalidStateTransition { message } =>
                (StatusCode::CONFLICT, "invalid_state_transition", message, None),
            Self::Internal =>
                (StatusCode::INTERNAL_SERVER_ERROR, "internal_error", "internal error".to_owned(), None),
        };

        let mut error = Map::new();
        error.insert("code".into(), json!(code));
        error.insert("message".into(), json!(message));
        if let Some(details) = details { error.insert("details".into(), details); }

        let mut response =
            (status, Json(json!({ "error": Value::Object(error) }))).into_response();
        if challenge {
            response.headers_mut().insert(
                header::WWW_AUTHENTICATE,
                HeaderValue::from_static(r#"Bearer realm="myapi""#),
            );
        }
        response
    }
}
```

A 401 must carry a `WWW-Authenticate` challenge header — that is part of the HTTP auth contract, easy to forget.

## Lifting layer errors with `From`

`From<DomainError>` and `From<StoreError>` are what let handlers write `decide(...)?` and `store.commit(...).await?`
and have the right status fall out. This is where the "what went wrong" → "which status" decision is encoded, once.

```rust
impl From<DomainError> for AppError {
    fn from(err: DomainError) -> Self {
        match err {
            DomainError::Validation { field, reason } =>
                Self::Validation { field: (!field.is_empty()).then_some(field), reason },
            err @ DomainError::InvalidStateTransition { .. } =>
                Self::InvalidStateTransition { message: err.to_string() },
        }
    }
}

impl From<StoreError> for AppError {
    fn from(err: StoreError) -> Self {
        match err {
            StoreError::VersionConflict =>
                Self::Conflict { message: "the resource was modified concurrently; retry".into() },
            StoreError::SlugConflict =>
                Self::Conflict { message: "a project with that slug already exists".into() },
            other => {
                tracing::error!(error = %other, "unhandled store error"); // log cause…
                Self::Internal                                            // …expose nothing
            }
        }
    }
}
```

## The payoff

With this in place, a handler's failure handling disappears into `?`:

```rust
let base = state.store.load_task(&id).await?      // StoreError → AppError → response
    .ok_or_else(|| AppError::not_found("task"))?; // Option → 404
let events = decide(&base, &cmd, now)?;           // DomainError → AppError → response
let task = state.store.commit_task(&id, Some(base), events, now).await?;
```

Rules of thumb:

- **Never leak internals.** Internal/DB errors map to a generic 500 with the cause logged via `tracing::error!`,
  never serialized to the client.
- **Distinguish expected from unexpected.** A 404/409/422 is a normal, typed outcome; only genuinely unexpected
  failures are `Internal`.
- **One envelope shape, everywhere.** Build it once in `IntoResponse`; every error path — including auth and
  body-parse failures — flows through it, so the contract's error schema is honored by construction.
