# Validation at the boundary & the error model

FastAPI + Pydantic v2 own the request edge: parse the body, reject what the contract forbids, and hand the domain a
clean command. The domain raises specific exceptions; a small set of handlers turns every one — including FastAPI's own
validation error — into a single error envelope. This is where contract conformance is won or lost.

## Pydantic v2 request models

Every request body is a Pydantic model. Three config decisions matter for contract fidelity:

```python
# api/schemas.py
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from ..domain.task import CaptureTask, EditTask, TaskState
from ..domain.optional import UNSET, Patch


class CreateTaskRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    title: str = Field(min_length=1)
    notes: str | None = None
    state: Literal["actionable", "backlogged"] = "actionable"
    project_ids: list[str] = Field(default_factory=list, alias="projectIds")
    start_date: str | None = Field(default=None, alias="startDate")
    due_date: str | None = Field(default=None, alias="dueDate")

    def to_command(self) -> CaptureTask:
        return CaptureTask(
            title=self.title,
            notes=self.notes,
            state=TaskState(self.state),
            start_date=_parse_date("startDate", self.start_date),
            due_date=_parse_date("dueDate", self.due_date),
            project_ids=tuple(self.project_ids),
        )
```

- **`extra="forbid"`** maps to OpenAPI `additionalProperties: false` and makes an unknown field a 422 instead of a
  silently-ignored typo. Use it on every request model.
- **`alias` + `populate_by_name=True`** lets the wire use camelCase (`projectId`, `dueDate`) while Python stays
  snake_case, and still accepts the Python name in tests.
- **`Field` constraints** (`min_length`, `ge`, `pattern`, …) are validation _and_ schema. Prefer them over manual checks.

### Strict parsing the framework won't do for you

Pydantic coerces generously by default — `"2026-13-40"` or `"true"` may slip through a `date`/`bool` in ways the
contract forbids, and date semantics (e.g. `startDate <= dueDate`) are domain rules. Two tactics:

1. Accept the raw `str` at the model boundary and parse **strictly** in `to_command()`, raising your domain
   `ValidationError` with the precise `field`/`reason`. This keeps the wire-level contract (a string) separate from the
   semantic rule (a valid, ordered date).
2. Use a `model_validator(mode="after")` for cross-field rules that are purely structural (e.g. "at least one field
   must be set" on a PATCH):

```python
class PatchTaskRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    title: str | None = Field(default=None, min_length=1)
    notes: str | None = None

    @model_validator(mode="after")
    def _at_least_one(self) -> PatchTaskRequest:
        if not self.model_fields_set:
            raise ValueError("patch must set at least one of: title, notes")
        return self

    def to_command(self) -> EditTask:
        # 3-valued PATCH: absent -> keep, null -> clear, value -> set.
        notes: Patch[str] = self.notes if "notes" in self.model_fields_set else UNSET
        return EditTask(title=self.title, notes=notes)
```

`model_fields_set` distinguishes "field absent" from "field sent as null" — essential for correct PATCH semantics. A
`type Patch[T] = T | None | UnsetType` alias (PEP 695) carries that three-state value into the domain.

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
  served document is authoritative. Simplest path; see `testing-and-contract.md`.
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
</content>
