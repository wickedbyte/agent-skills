# Bootstrap & config: the app factory, lifespan, settings & dependency injection

Get the factory, the lifespan, and the DI wiring right and everything else slots in. All examples are fully typed and
assume `best-practices-python` style (modern syntax, frozen dataclasses, enums).

## The app factory

Build the app in a function so tests can inject fakes (a store backed by a throwaway DB, a frozen clock) and production
builds the real collaborators. Never construct engines or clients at import time.

```python
# main.py
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from datetime import UTC, datetime

from fastapi import Depends, FastAPI
from fastapi.responses import JSONResponse

from .api import commands, errors, events, health, projects, tasks
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

    # Open probes — no token (the balancer/orchestrator carries none). Shallow + bodyless.
    @app.get("/readyz")
    async def readyz() -> JSONResponse:  # readiness — can we actually serve traffic right now?
        try:
            await resolved_store.ping()  # cheap `SELECT 1` on a pooled connection
        except Exception:  # noqa: BLE001 — any failure means "not ready"
            return JSONResponse({"status": "unavailable"}, status_code=503)
        return JSONResponse({"status": "ready"})

    @app.get("/livez")
    async def livez() -> JSONResponse:  # liveness — is the process up? open, bodyless, always 200
        return JSONResponse({"status": "ok"})

    # `/healthz` is the richer report (component/dependency status + build/version). Because that
    # detail leaks internal topology it sits BEHIND auth — register it on a gated router, not here.
    app.include_router(health.router, dependencies=gated)

    return app
```

`/healthz` lives on its own gated router so it inherits the same `require_auth` gate as the business routers — open when
`AUTH_REQUIRED=false`, token-gated when it's on:

```python
# api/health.py
from fastapi import APIRouter, Request

router = APIRouter()


@router.get("/healthz")
async def healthz(request: Request) -> dict[str, object]:
    store = request.app.state.store
    settings = request.app.state.settings
    db_ok = True
    try:
        await store.ping()
    except Exception:  # noqa: BLE001 — report degraded rather than 500
        db_ok = False
    return {
        "status": "ok" if db_ok else "degraded",
        "version": settings.build_version,
        "dependencies": {"database": "up" if db_ok else "down"},
    }
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
    build_version: str = "dev"  # surfaced by the gated /healthz report
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
