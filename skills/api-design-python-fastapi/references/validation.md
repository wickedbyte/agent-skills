# Validation at the boundary

FastAPI + Pydantic v2 own the request edge: parse the body, reject what the contract forbids, and hand the domain a
clean command. This reference covers the Pydantic v2 request models and the strict parsing the framework won't do for
you; the error model that turns failures into a single envelope lives in `references/errors.md`.

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
