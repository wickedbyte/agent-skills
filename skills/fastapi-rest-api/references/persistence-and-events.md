# Persistence (async SQLAlchemy + asyncpg) & server-sent events

The persistence layer is async end-to-end: an async engine, async sessions, transactional writes, and optimistic
concurrency. This reference shows the engine/session setup, the transactional write path, projections, Alembic async
migrations, and SSE over Postgres `LISTEN/NOTIFY`. The patterns generalize to any FastAPI service; the event-sourcing
specifics are one concrete instance of "write atomically, then read your writes."

## Engine and sessions

One async engine per process, built in the factory and disposed in `lifespan`. `expire_on_commit=False` so objects
remain usable after commit (and so you never trigger a lazy reload — forbidden under async).

```python
# db.py
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)


def create_engine(database_url: str, *, pool_size: int = 10, max_overflow: int = 5) -> AsyncEngine:
    return create_async_engine(
        database_url,                  # "postgresql+asyncpg://user:pw@host/db"
        pool_pre_ping=True,            # recycle dead connections transparently
        pool_size=pool_size,
        max_overflow=max_overflow,
    )


def create_session_factory(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False)
```

**Pool sizing across workers.** Total connections = `workers × (pool_size + max_overflow)` plus any out-of-pool
connections (an SSE LISTEN connection is one *per subscriber* or one shared). Keep the fleet under Postgres
`max_connections`; derive per-worker pool sizes from a configured budget in `Settings`, don't hardcode.

### ORM vs Core

You do **not** need mapped ORM classes. For an append-only event store, SQLAlchemy **Core** with `text()` parameterized
statements is clearer and faster than mapping — you're writing one INSERT and a handful of SELECTs. Use the ORM only
where rich object graphs and relationship loading earn their keep, and if you do, **eager-load** everything a response
needs (`selectinload`/`joinedload`) because async sessions forbid implicit lazy loading.

## The transactional write path

The core rule: **append the event and update the projection in one transaction**, so a reader immediately sees the
write (read-your-writes), and a concurrent writer is rejected rather than interleaved.

```python
# store/event_store.py
import json
from datetime import datetime

from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..domain.task import Task, apply
from ..domain.events import Event
from .codec import encode_event_data
from .errors import VersionConflictError, map_integrity_error
from .projections import write_task_projection

_APPEND = text(
    "INSERT INTO events (id, stream_type, stream_id, version, type, data, occurred_at) "
    "VALUES (:id, :stream_type, :stream_id, :version, :type, CAST(:data AS jsonb), :occurred_at)"
)
_NOTIFY = text("SELECT pg_notify('app_events', :event_id)")


class EventStore:
    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._session_factory = session_factory

    async def commit_task(
        self, stream_id: str, base: Task, proposed: list[Event], now: datetime
    ) -> tuple[Task, list[Event]]:
        """Append events + update the projection + notify, atomically. Returns new state."""
        committed: list[Event] = []
        state = base
        for offset, event in enumerate(proposed):
            stamped = event.stamp(stream_id, version=base.version + 1 + offset, occurred_at=now)
            state = apply(state, stamped)
            committed.append(stamped)

        async with self._session_factory() as session, session.begin():
            for event in committed:
                params = {
                    "id": event.id,
                    "stream_type": event.stream_type,
                    "stream_id": event.stream_id,
                    "version": event.version,
                    "type": event.type,
                    "data": json.dumps(encode_event_data(event.data)),
                    "occurred_at": event.occurred_at,
                }
                try:
                    await session.execute(_APPEND, params)
                except IntegrityError as exc:
                    mapped = map_integrity_error(exc)   # -> VersionConflictError / SlugConflictError
                    raise (mapped or exc) from exc
            await write_task_projection(session, state)         # same transaction
            for event in committed:
                await session.execute(_NOTIFY, {"event_id": event.id})  # SSE wakeup

        return state, committed
```

`async with self._session_factory() as session, session.begin():` opens the session and a transaction; the block commits
on success and rolls back on any exception — append, projection, and notify all land together or not at all.

## Optimistic concurrency

The events table carries `UNIQUE (stream_type, stream_id, version)`. The writer computes the next version from the state
it loaded (`base.version + 1`). If another writer committed in between, the INSERT hits the unique constraint and raises
`IntegrityError`; translate that to a domain `VersionConflictError` → 409. No locks, no lost updates.

```sql
-- migration DDL
CREATE TABLE events (
    id          text        PRIMARY KEY,
    stream_type text        NOT NULL,
    stream_id   text        NOT NULL,
    version     integer     NOT NULL CHECK (version >= 1),
    type        text        NOT NULL,
    data        jsonb       NOT NULL,
    occurred_at timestamptz NOT NULL,
    CONSTRAINT events_stream_version_unique UNIQUE (stream_type, stream_id, version)
);
```

```python
# store/errors.py
from sqlalchemy.exc import IntegrityError


def map_integrity_error(exc: IntegrityError) -> Exception | None:
    constraint = getattr(getattr(exc.orig, "__cause__", None), "constraint_name", "")
    if constraint == "events_stream_version_unique":
        return VersionConflictError()
    return None  # let the original raise — don't mask an unexpected violation
```

Match on the **constraint name**, not on string-scraping the message; return `None` for anything you didn't expect so a
genuine bug surfaces instead of being mislabeled a conflict.

## Projections

Projections are read-model caches, written in the same transaction and fully reproducible by replaying events from
version 1. Upsert the row; for ordered collections, delete-and-reinsert the edges wholesale so order is authoritative.

```python
# store/projections.py
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from ..domain.task import Task

_UPSERT = text(
    """
    INSERT INTO task_projection (id, title, state, version, created_at, updated_at)
    VALUES (:id, :title, :state, :version, :created_at, :updated_at)
    ON CONFLICT (id) DO UPDATE SET
        title = EXCLUDED.title, state = EXCLUDED.state,
        version = EXCLUDED.version, updated_at = EXCLUDED.updated_at
    """
)


async def write_task_projection(session: AsyncSession, task: Task) -> None:
    await session.execute(
        _UPSERT,
        {
            "id": task.id, "title": task.title, "state": task.state.value,
            "version": task.version, "created_at": task.created_at, "updated_at": task.updated_at,
        },
    )
```

Because projections are derived, a "rebuild" command that truncates them and folds every event back in must reproduce
them exactly — a property worth an integration test.

## Querying

Parameterize with bind params and cast nullable filters so a single statement handles optional criteria without string
concatenation:

```python
_LIST = text(
    """
    SELECT * FROM task_projection
    WHERE (CAST(:state AS text) IS NULL OR state = CAST(:state AS text))
      AND (CAST(:include_completed AS boolean) OR state <> 'completed')
    ORDER BY created_at, id
    """
)
```

Never f-string user input into SQL. `text()` + bind params (`:state`) is the injection-safe path; on 3.14 a t-string
processed by an escaping layer is the idiomatic alternative for dynamic fragments, but bound parameters cover the
common case.

## Alembic async migrations

Alembic's `env.py` runs migrations through the async engine. Run migrations **out of band** — a one-shot container or
`make migrate-up` — never inside `lifespan`, so N workers don't race.

```python
# migrations/env.py (online section)
import asyncio

from alembic import context
from sqlalchemy.ext.asyncio import async_engine_from_config


def _run_migrations(connection: object) -> None:
    context.configure(connection=connection, target_metadata=None)  # raw-SQL migrations: no metadata
    with context.begin_transaction():
        context.run_migrations()


async def _run_async() -> None:
    engine = async_engine_from_config(context.config.get_section(context.config.config_ini_section, {}))
    async with engine.connect() as connection:
        await connection.run_sync(_run_migrations)
    await engine.dispose()


asyncio.run(_run_async())
```

`upgrade head` then `downgrade base` must round-trip cleanly — test it. Prefer explicit raw-SQL `op.execute(...)`
migrations for an event store; you control exact DDL (constraints, partial indexes, generated columns) that autogenerate
would miss.

## Server-sent events over `LISTEN/NOTIFY`

A single shared asyncpg connection issues `LISTEN`; on each `NOTIFY` it fans the event id to every subscriber's
`asyncio.Queue`. Each `EventSourceResponse` backfills from the events table (`WHERE id > :last_seen`) before going live,
so `Last-Event-ID` resumes exactly after the last delivered event.

```python
# sse.py
import asyncio
from collections.abc import AsyncIterator

import asyncpg


class SseHub:
    def __init__(self, dsn: str) -> None:
        self._dsn = dsn
        self._conn: asyncpg.Connection | None = None
        self._subscribers: set[asyncio.Queue[str]] = set()

    async def start(self) -> None:
        self._conn = await asyncpg.connect(self._dsn)
        await self._conn.add_listener("app_events", self._on_notify)

    async def stop(self) -> None:
        if self._conn is not None:
            await self._conn.close()

    def _on_notify(self, _conn: object, _pid: int, _channel: str, event_id: str) -> None:
        for queue in self._subscribers:
            queue.put_nowait(event_id)          # wake every live subscriber

    async def subscribe(self) -> AsyncIterator[str]:
        queue: asyncio.Queue[str] = asyncio.Queue()
        self._subscribers.add(queue)
        try:
            while True:
                yield await queue.get()
        finally:
            self._subscribers.discard(queue)    # always clean up on disconnect
```

```python
# api/events.py
from fastapi import APIRouter, Header, Request
from sse_starlette.sse import EventSourceResponse

router = APIRouter()


@router.get("/events")
async def stream_events(request: Request, last_event_id: str | None = Header(default=None)) -> EventSourceResponse:
    hub: SseHub = request.app.state.hub
    store: EventStore = request.app.state.store

    async def gen() -> AsyncIterator[dict[str, str]]:
        last_seen = last_event_id or ""
        # 1) backfill everything after Last-Event-ID
        for event in await store.events_after(last_seen):
            last_seen = event.id
            yield {"id": event.id, "event": event.sse_name, "data": event.sse_data}
        # 2) go live
        async for event_id in hub.subscribe():
            if event_id <= last_seen:
                continue                          # skip anything already backfilled (ULIDs sort lexically)
            for event in await store.events_after(last_seen):
                last_seen = event.id
                yield {"id": event.id, "event": event.sse_name, "data": event.sse_data}

    return EventSourceResponse(gen())
```

Key points: keep the NOTIFY payload small (send the event **id**, fetch the row in the handler — payloads have a size
limit); the listener connection lives **outside** the SQLAlchemy pool; and use sortable ids (ULIDs) so `WHERE id >
:last_seen ORDER BY id` is a correct, index-friendly backfill. Test subscribe → mutate → assert-frame, and
reconnect-with-`Last-Event-ID` → later-events-only.
</content>
