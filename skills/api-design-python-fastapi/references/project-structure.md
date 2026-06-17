# Project structure, the app factory, settings & dependency injection

This is the load-bearing reference: get the layering, the factory, and the DI wiring right and everything else slots in.
All examples are fully typed and assume `best-practices-python` style (modern syntax, frozen dataclasses, enums).

## The layered shape

Dependencies point **inward**. The domain core is pure and import-clean; persistence depends on the domain; only the
api layer depends on FastAPI.

```
src/<pkg>/
  main.py            # create_app() + lifespan + __main__ uvicorn entry
  config.py          # Settings (pydantic-settings)
  db.py              # async engine + session factory
  domain/            # NO fastapi / sqlalchemy / pydantic import
    errors.py        #   exception hierarchy (ValidationError, StateTransitionError, …)
    events.py        #   event/value-object dataclasses, enums
    <aggregate>.py   #   decide()/apply() pure functions
  store/             # NO fastapi import
    event_store.py   #   transactional append + queries
    projections.py   #   projection writers
    codec.py         #   snake_case <-> camelCase, date/datetime encoding
    errors.py        #   VersionConflictError, NotFoundError, …
  api/               # the only FastAPI-aware layer
    deps.py          #   Depends() providers + Annotated aliases
    schemas.py       #   Pydantic request/response models
    errors.py        #   exception handlers -> envelope
    <resource>.py    #   APIRouter per resource
    commands.py      #   RPC colon-routes
```

**Why a domain core with no framework imports.** It is unit-testable in microseconds, it cannot be coupled to a request
lifecycle by accident, and the rules live in exactly one place. The HTTP layer shrinks to translation, which is why it
needs so few tests of its own.

## The app factory

Build the app in a function so tests can inject fakes (a store backed by a throwaway DB, a frozen clock) and production
builds the real collaborators. Never construct engines or clients at import time.

```python
# main.py
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from datetime import UTC, datetime

from fastapi import Depends, FastAPI

from .api import commands, errors, events, projects, tasks
from .api.auth import require_auth
from .config import Settings, load_settings
from .db import create_engine, create_session_factory
from .store.event_store import EventStore


def _utcnow() -> datetime:
    return datetime.now(UTC)


def create_app(
    *,
    settings: Settings | None = None,
    store: EventStore | None = None,
    clock: Callable[[], datetime] | None = None,
) -> FastAPI:
    """Construct the application. Tests pass `store`/`clock`; production builds them."""
    cfg = settings if settings is not None else load_settings()

    owns_engine = store is None
    engine = create_engine(cfg.database_url) if owns_engine else None
    resolved_store = EventStore(create_session_factory(engine)) if engine is not None else store
    assert resolved_store is not None  # for the type checker; one branch always runs

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        # startup: warm pools, start the SSE listener, etc.
        yield
        # shutdown: release what this factory owns
        if engine is not None:
            await engine.dispose()

    app = FastAPI(title="Taskflow", version="1.0.0", lifespan=lifespan)

    # Stash collaborators on app.state; deps.py reads them (see "Dependency injection").
    app.state.settings = cfg
    app.state.store = resolved_store
    app.state.clock = clock if clock is not None else _utcnow

    errors.register_error_handlers(app)

    gated = [Depends(require_auth)]  # auth gate applied to business routers only
    app.include_router(tasks.router, dependencies=gated)
    app.include_router(commands.router, dependencies=gated)
    app.include_router(projects.router, dependencies=gated)
    app.include_router(events.router, dependencies=gated)

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:  # always open — never gated
        return {"status": "ok"}

    return app
```

The `__main__` entry runs uvicorn programmatically so `python -m <pkg>.main` is the container entrypoint:

```python
def main() -> None:
    import uvicorn

    cfg = load_settings()
    uvicorn.run("<pkg>.main:create_app", factory=True, host="0.0.0.0", port=cfg.port, workers=cfg.workers)


if __name__ == "__main__":
    main()
```

### `lifespan`, not `on_event`

`@app.on_event("startup"/"shutdown")` is deprecated. The `lifespan` async context manager is the modern, type-clean
replacement: everything before `yield` is startup, everything after is shutdown, and it composes naturally with other
async context managers (a DB pool, an SSE listener, a background `TaskGroup`).

```python
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    await app.state.hub.start()           # e.g. open the asyncpg LISTEN connection
    try:
        yield
    finally:
        await app.state.hub.stop()
```

**Migrations do not belong in `lifespan`.** Run Alembic out of band (a one-shot container or a `make` target) so N
workers don't race to migrate. The app should assume the schema is present.

## Settings with `pydantic-settings`

One typed `Settings` object, sourced from the environment, validated once. Never reach into `os.environ` from business
code.

```python
# config.py
from functools import lru_cache

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", extra="ignore")

    port: int = 8080
    database_url: str = "postgresql+asyncpg://app:app@localhost:5432/app"
    workers: int = Field(default=1, validation_alias=AliasChoices("WORKERS", "WEB_CONCURRENCY"))

    auth_required: bool = False
    auth_jwks_url: str = ""
    auth_issuer: str = ""
    auth_audience: str = ""


@lru_cache
def load_settings() -> Settings:
    return Settings()
```

`AliasChoices` lets one field read either of two env vars. `lru_cache` makes `load_settings()` a process-wide singleton
without a module global. Field names map to upper-case env vars (`database_url` ← `DATABASE_URL`).

## Dependency injection with `Depends` + `Annotated`

FastAPI's DI is the framework-idiomatic substitute for hand-rolled constructor injection. Define small **provider**
functions that read from `app.state`, then publish **`Annotated` aliases** so handlers declare a clean type.

```python
# api/deps.py
from collections.abc import Callable
from datetime import datetime
from typing import Annotated

from fastapi import Depends, Request

from ..store.event_store import EventStore


def get_store(request: Request) -> EventStore:
    store: EventStore = request.app.state.store
    return store


def get_clock(request: Request) -> Callable[[], datetime]:
    clock: Callable[[], datetime] = request.app.state.clock
    return clock


Store = Annotated[EventStore, Depends(get_store)]
Clock = Annotated[Callable[[], datetime], Depends(get_clock)]
```

Handlers then read like plain functions — no globals, no construction:

```python
# api/tasks.py
from fastapi import APIRouter

from .deps import Clock, Store

router = APIRouter()


@router.get("/tasks/{task_id}")
async def get_task(task_id: str, store: Store) -> dict[str, object]:
    task = await store.get_task(task_id)
    ...
```

Patterns worth knowing:

- **Reading from `app.state`** keeps providers trivial and makes the factory the single wiring point. Injecting a fake
  store in a test is just `create_app(store=fake)`.
- **`yield` dependencies** for per-request resources that need teardown (`async def get_session(...) -> AsyncIterator`).
- **Router-level dependencies** (`include_router(r, dependencies=[Depends(require_auth)])`) apply a gate to a whole
  router without threading it through every signature. Use this for auth.
- **`dependency_overrides`** is the official seam for swapping a provider in tests when you don't want to rebuild the
  app: `app.dependency_overrides[get_clock] = lambda: fixed`.

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

## Toolchain skeleton

- **`pyproject.toml`** — PEP 621 metadata, runtime deps under `[project].dependencies`, dev tools under
  `[dependency-groups].dev` (so they don't leak into the wheel), and all tool config (`[tool.ruff]`, `[tool.mypy]`,
  `[tool.pytest.ini_options]`) in the one file. Commit `uv.lock`.
- **`Makefile`** — the mechanical gate as targets: `fmt-check` (`ruff format --check`), `lint` (`ruff check`), `types`
  (`mypy --strict src`), `test` (`pytest`), and a `gate` that runs all four in order. Add `up`/`down`/`logs` for the
  compose stack and `migrate-up`/`migrate-down` for Alembic.
- **`Dockerfile`** — multi-stage on the `ghcr.io/astral-sh/uv` image: `uv sync --frozen --no-dev` into a venv, copy the
  source, drop to a non-root user, `ENTRYPOINT ["python", "-m", "<pkg>.main"]`. Pull the **current** uv base image tag;
  don't hardcode one from memory.
- **`compose.yaml`** — the app plus its own `postgres` (and `valkey` if you use it), with a one-shot `migrate` service
  (`depends_on: postgres: condition: service_healthy`) that the app waits on via
  `condition: service_completed_successfully`.

Keep `pytest.ini_options` configured for async: `asyncio_mode = "auto"`, `pythonpath = ["src"]`, and any custom markers
(`conformance`, `sse`) you select tests by.
</content>
