# Testing the API & proving the OpenAPI contract

The test strategy mirrors the layering: a wide base of fast pure-domain unit tests, fewer store/integration tests, fewer
still HTTP functional tests, and a contract layer that proves the wire shape two independent ways. The discipline is
**push behaviour down**: exhaustively test the rules in the pure core, and let the HTTP tests cover only translation.

## The pyramid

| Layer           | Scope                                   | Tools                                  | Speed    |
| --------------- | --------------------------------------- | -------------------------------------- | -------- |
| **unit**        | pure domain (`decide`/`apply`, parsing) | pytest                                 | microsec |
| **integration** | store + a real database                 | pytest-asyncio + asyncpg/SQLAlchemy    | ms       |
| **functional**  | HTTP black-box, in-process              | pytest-asyncio + httpx `ASGITransport` | ms       |
| **contract**    | emitted spec ≡ canonical; fuzzing       | pytest + Schemathesis                  | sec      |

Put each in its own `tests/<layer>/` directory; mark slow/categorical ones (`@pytest.mark.conformance`,
`@pytest.mark.sse`) so CI can select them.

## pytest + async config

```toml
# pyproject.toml
[tool.pytest.ini_options]
asyncio_mode = "auto"          # plain `async def test_…` — no per-test decorator
testpaths = ["tests"]
pythonpath = ["src"]
markers = [
    "conformance: behavioral invariant scenarios",
    "sse: server-sent-events scenarios",
]
```

`asyncio_mode = "auto"` lets you write `async def test_x() -> None:` directly. Keep every test annotated `-> None` and
fully typed — tests are code the checker should cover too.

## Unit tests: the domain core

The bulk of behaviour lives here, with no DB and no HTTP — so they're instant and you can afford one per rule.
Parametrize tables of cases; assert on the precise exception and its fields.

```python
import pytest

from <pkg>.domain.task import CaptureTask, CompleteTask, Task, TaskState, decide
from <pkg>.domain.errors import StateTransitionError, ValidationError

NOW = datetime(2026, 6, 16, 12, 0, tzinfo=UTC)


def test_capture_requires_title() -> None:
    with pytest.raises(ValidationError) as ei:
        decide(Task(), CaptureTask(title=""), NOW)
    assert ei.value.field == "title"


def test_complete_on_terminal_state_rejected() -> None:
    done = Task(state=TaskState.COMPLETED, version=1)
    with pytest.raises(StateTransitionError):
        decide(done, CompleteTask(), NOW)
```

## Integration tests: the store against a real database

Use a real Postgres (a compose service or testcontainer), migrate once per session, and isolate tests by truncating
projections (keep the events table if you test replay). Inject the store via fixtures.

```python
# tests/conftest.py
import os
from collections.abc import AsyncIterator, Callable, Iterator
from datetime import UTC, datetime

import httpx
import pytest
from alembic import command
from httpx import ASGITransport
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine

from <pkg>.main import create_app
from <pkg>.store.event_store import EventStore

FIXED_NOW = datetime(2026, 6, 16, 12, 0, tzinfo=UTC)


@pytest.fixture(scope="session")
def db_url() -> str:
    return os.environ.get("DATABASE_URL", "postgresql+asyncpg://app:app@localhost:5436/app")


@pytest.fixture(scope="session")
def migrated_db(db_url: str) -> Iterator[str]:
    cfg = alembic_config(db_url)
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    yield db_url


@pytest.fixture
async def engine(migrated_db: str) -> AsyncIterator[AsyncEngine]:
    eng = create_async_engine(migrated_db)
    async with eng.begin() as conn:
        await conn.execute(text("TRUNCATE task_projection, events CASCADE"))
    yield eng
    await eng.dispose()


@pytest.fixture
def store(engine: AsyncEngine) -> EventStore:
    return EventStore(async_sessionmaker(engine, expire_on_commit=False))


@pytest.fixture
def fixed_clock() -> Callable[[], datetime]:
    return lambda: FIXED_NOW
```

```python
async def test_stale_version_conflicts(store: EventStore) -> None:
    base = Task()
    state, _ = await store.commit_task("task_1", base, decide(base, CaptureTask(title="x"), NOW), NOW)
    assert state.version == 1
    # re-using the stale base (v1) collides on v2
    with pytest.raises(VersionConflictError):
        await store.commit_task("task_1", base, decide(base, CompleteTask(), NOW), NOW)
```

## Functional tests: HTTP in-process with `httpx.ASGITransport`

`ASGITransport` drives the ASGI app directly — no uvicorn, no socket, no port — so functional tests are nearly as fast
as unit tests and fully deterministic. Build the app with the **injected** store and a frozen clock so timestamps are
reproducible.

```python
@pytest.fixture
async def client(store: EventStore, fixed_clock: Callable[[], datetime]) -> AsyncIterator[httpx.AsyncClient]:
    app = create_app(store=store, clock=fixed_clock)
    transport = ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        yield c            # lifespan runs around the `async with` if you use httpx's lifespan support


async def test_create_then_get_roundtrips(client: httpx.AsyncClient) -> None:
    created = await client.post("/tasks", json={"title": "ship it"})
    assert created.status_code == 201
    tid = created.json()["task"]["id"]

    fetched = await client.get(f"/tasks/{tid}")
    assert fetched.status_code == 200
    assert fetched.json()["task"]["title"] == "ship it"


async def test_unknown_field_rejected(client: httpx.AsyncClient) -> None:
    resp = await client.post("/tasks", json={"title": "x", "bogus": 1})
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_failed"   # your envelope, not FastAPI's default
```

If your `lifespan` opens real resources (an SSE listener), either inject a fake hub for functional tests or wrap the
client in `LifespanManager` (from `asgi-lifespan`) so startup/shutdown actually run.

## Contract layer 1: emitted OpenAPI ≡ canonical

The app must agree with the frozen spec. Decide the strategy up front:

- **Serve canonical verbatim** — load `openapi.yaml`, override `app.openapi` to return it, and serve it at
  `/openapi.json`. The contract is authoritative by construction; the test just guards that you didn't drift the routes
  away from it.
- **Emit from routes/models** — let FastAPI generate the schema; the test normalizes and compares it to the canonical
  doc, and you reconcile differences (notably the 422 schema — see `validation-and-errors.md`).

```python
# tests/contract/test_openapi.py
from pathlib import Path

import yaml

from <pkg>.main import create_app

CANONICAL = yaml.safe_load(Path("../openapi.yaml").read_text())
_HTTP_METHODS = {"get", "post", "put", "patch", "delete"}


def test_emitted_openapi_equals_canonical() -> None:
    assert create_app().openapi() == CANONICAL


def test_every_documented_route_is_implemented() -> None:
    app = create_app()
    documented = {
        (method.upper(), path)
        for path, item in CANONICAL["paths"].items()
        for method in item
        if method in _HTTP_METHODS
    }
    implemented = {
        (method, getattr(route, "path", ""))
        for route in app.routes
        for method in getattr(route, "methods", set()) or set()
    }
    missing = documented - implemented
    assert not missing, f"documented but not implemented: {sorted(missing)}"
```

The route-coverage test catches the asymmetric failure the equality test can miss when you serve canonical verbatim: a
documented path with no handler. Add the reverse check (implemented but undocumented) if your contract must be exhaustive.

## Contract layer 2: Schemathesis property-based fuzzing

The equality test proves the _documented_ shape; Schemathesis proves the _running_ app honours it — it generates
edge-case requests from the schema and asserts every response conforms (status in the documented set, body matches the
declared schema, no 500s, no undeclared fields). Run it as pytest tests or as a CLI step in CI against the live
container.

```python
# tests/contract/test_fuzz.py
import schemathesis

schema = schemathesis.openapi.from_path("../openapi.yaml", base_url="http://localhost:8080")


@schema.parametrize()
def test_api_conforms_to_spec(case: schemathesis.Case) -> None:
    case.call_and_validate()       # generate -> send -> assert response matches the schema
```

Or from the CLI (verify the current invocation — the CLI surface evolves between major versions):

```bash
uv run st run ../openapi.yaml --url http://localhost:8080
```

Schemathesis is property-based: each failure is minimized and replayed as a reproducible request, so a red run hands you
the exact payload that broke the contract. Treat any failure as a contract bug in the implementation, not the spec —
the spec is frozen.

## What not to test

- **Don't unit-test logging.** Assert behaviour and responses, not log lines.
- **Don't re-test the framework.** You don't need a test proving FastAPI parses an int path param; test _your_ rules.
- **Don't mock the database in integration tests.** A fake that accepts any SQL proves nothing about the constraints
  (the unique-version collision, the date CHECK) you rely on — use a real Postgres.

## The mechanical gate

The whole suite sits behind one gate, every step green before advancing:

```
ruff format --check .     # formatting
ruff check .              # lint
mypy --strict src         # types — the real correctness signal
pytest                    # unit -> integration -> functional -> contract
```

Wire it as `make gate` and run it in CI. A step is done only when the gate exits zero across the board (plus, where it
applies, the emitted-OpenAPI ≡ canonical contract test and a clean Schemathesis run).
</content>
