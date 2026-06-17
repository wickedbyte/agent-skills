# The error model

The domain raises specific exceptions; a small set of handlers turns every one — including FastAPI's own validation
error — into a single error envelope. This is where contract conformance is won or lost. Boundary validation (the
Pydantic request models) lives in `references/validation.md`.

## The error envelope

Define the envelope once and a typed code→status map. A representative contract:

```json
{
    "error": {
        "code": "validation_failed",
        "message": "…",
        "details": { "field": "dueDate", "reason": "…" }
    }
}
```

| code                       | status |
| -------------------------- | ------ |
| `validation_failed`        | 422    |
| `not_found`                | 404    |
| `conflict`                 | 409    |
| `invalid_state_transition` | 409    |
| `internal_error`           | 500    |

```python
# api/errors.py
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


def error_response(status: int, code: str, message: str, details: dict[str, Any] | None = None) -> JSONResponse:
    body: dict[str, Any] = {"error": {"code": code, "message": message}}
    if details:
        body["error"]["details"] = details
    return JSONResponse(status_code=status, content=body)
```

## A domain exception hierarchy

The domain raises problem-named exceptions (per `best-practices-python`); the store raises persistence ones. Neither
knows about HTTP — the handlers do the mapping.

```python
# domain/errors.py
class DomainError(Exception):
    """Base for domain rule violations."""


class ValidationError(DomainError):
    def __init__(self, field: str, reason: str) -> None:
        super().__init__(reason)
        self.field = field
        self.reason = reason


class StateTransitionError(DomainError):
    """A command issued against a terminal/illegal state (409)."""
```

## Wiring the handlers

Register one handler per exception type, plus the two FastAPI/Starlette built-ins. Keep this function the single place
HTTP status is decided.

```python
# api/errors.py (continued)
from ..domain.errors import StateTransitionError, ValidationError
from ..store.errors import NotFoundError, VersionConflictError


def register_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ValidationError)
    async def _on_validation(_: Request, exc: ValidationError) -> JSONResponse:
        details = {"field": exc.field, "reason": exc.reason} if exc.field else None
        return error_response(422, "validation_failed", exc.reason, details)

    @app.exception_handler(NotFoundError)
    async def _on_not_found(_: Request, exc: NotFoundError) -> JSONResponse:
        return error_response(404, "not_found", f"{exc.resource} not found")

    @app.exception_handler(StateTransitionError)
    async def _on_state(_: Request, exc: StateTransitionError) -> JSONResponse:
        return error_response(409, "invalid_state_transition", str(exc))

    @app.exception_handler(VersionConflictError)
    async def _on_conflict(_: Request, _exc: VersionConflictError) -> JSONResponse:
        return error_response(409, "conflict", "the resource was modified concurrently; retry")

    # --- The 422 reconciliation (see below) ---
    @app.exception_handler(RequestValidationError)
    async def _on_request_validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        errors = exc.errors()
        message = str(errors[0]["msg"]) if errors else "request validation failed"
        first = errors[0] if errors else None
        details = None
        if first and first.get("loc"):
            field = str(first["loc"][-1])
            details = {"field": field, "reason": message}
        return error_response(422, "validation_failed", message, details)
```

## The FastAPI 422 reconciliation — the classic contract failure

This is the single most common place the emitted-spec ≡ canonical check fails, so give it attention.

**The body.** When a request fails Pydantic validation, FastAPI raises `RequestValidationError` and, by default, returns
its _own_ body shape: `{"detail": [{"loc": [...], "msg": "...", "type": "..."}]}`. That is not your envelope. Install the
`RequestValidationError` handler above so the **body** becomes `{"error": {"code": "validation_failed", …}}` while the
**status stays 422**. (Also override `HTTPException` if any default FastAPI 404/405 could leak its `{"detail": "..."}`
shape.)

**The schema.** FastAPI also _documents_ a generated `HTTPValidationError` schema for every operation's 422. If your
canonical spec documents 422 with your `ErrorEnvelope` instead, the generated OpenAPI won't match. Two fixes:

- If you **serve a canonical `openapi.yaml` verbatim** (override `app.openapi`), the generated schema never ships — the
  served document is authoritative. Simplest path; see `openapi-contract.md`.
- If you **let FastAPI emit** the schema, override each operation's documented 422 response to reference your envelope:

```python
COMMON_ERRORS: dict[int | str, dict[str, Any]] = {
    422: {"model": ErrorEnvelope, "description": "Validation failed"},
    409: {"model": ErrorEnvelope, "description": "Conflict"},
}

@router.post("/tasks", responses=COMMON_ERRORS)
async def create_task(...) -> ...: ...
```

and, if needed, post-process `app.openapi()` once to strip the auto-injected `HTTPValidationError`/`ValidationError`
component schemas so they don't appear as undocumented extras.

## Catch narrowly; never swallow

A bare `except Exception` that returns a 500 envelope is acceptable **only** as a last-resort handler that also logs the
traceback — and it must be the outermost net, not a substitute for specific handlers. Let unexpected exceptions become a
deliberately generic `internal_error` (never echo internals to the client), and make sure every _expected_ failure has
a specific handler above it so it maps to the right status and a useful message.
