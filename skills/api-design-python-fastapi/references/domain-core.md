# The pure domain core

The domain core is where the rules live. It imports nothing framework-shaped — no FastAPI, SQLAlchemy, or Pydantic — so
it is unit-testable in microseconds and the rules sit in exactly one place. All examples are fully typed and assume
`best-practices-python` style (frozen dataclasses, enums, pure functions).

## The pure domain core (sketch)

The domain owns the rules and nothing else — see `best-practices-python` for the style. A representative pure command
handler:

```python
# domain/task.py
from dataclasses import dataclass, replace
from datetime import datetime
from enum import StrEnum

from .errors import StateTransitionError, ValidationError
from .events import Event, TaskCaptured, TaskCompleted


class TaskState(StrEnum):
    ACTIONABLE = "actionable"
    COMPLETED = "completed"
    CANCELLED = "cancelled"

    @property
    def is_terminal(self) -> bool:
        return self in (TaskState.COMPLETED, TaskState.CANCELLED)


@dataclass(frozen=True, slots=True)
class Task:
    id: str = ""
    title: str = ""
    state: TaskState = TaskState.ACTIONABLE
    version: int = 0


def decide(state: Task, cmd: "TaskCommand", now: datetime) -> list[Event]:
    """Validate a command against current state; return events to append. Pure."""
    match cmd:
        case CaptureTask(title=""):
            raise ValidationError("title", "title is required")
        case CaptureTask(title=title):
            return [TaskCaptured(title=title)]
        case CompleteTask() if state.state.is_terminal:
            raise StateTransitionError(f"cannot complete a {state.state} task")
        case CompleteTask():
            return [TaskCompleted(completed_at=now)]
    raise AssertionError("unreachable")  # exhaustive match; or use typing.assert_never


def apply(state: Task, event: Event) -> Task:
    """Fold one event into state. Pure."""
    match event:
        case TaskCaptured(title=title):
            return replace(state, title=title, version=event.version)
        case TaskCompleted():
            return replace(state, state=TaskState.COMPLETED, version=event.version)
    raise AssertionError("unreachable")
```

The clock is **injected** (`now: datetime`), never read inside the domain — that is what makes timestamp behaviour
deterministically testable.
