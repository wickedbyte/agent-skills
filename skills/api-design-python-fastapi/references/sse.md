# Server-sent events over `LISTEN/NOTIFY`

Streaming events to clients builds on the persistence layer (`references/persistence.md`): the transactional write path
issues a Postgres `NOTIFY`, and this reference fans those notifications out to subscribers over SSE.

**Scaling caveat — read before you build.** The in-process `LISTEN/NOTIFY` fan-out shown below holds one
long-lived connection per subscriber inside the app process. That is fine for a proof of concept or a
low-concurrency internal tool — roughly **under 100 concurrent streams on a single instance** — but it does
**not** scale: open connections pin memory and file descriptors to specific instances, every deploy drops
every stream, and horizontal scaling multiplies the `LISTEN` load on Postgres. **For production, or anything
user-facing at scale, do not fan out from the app.** Put a GRIP-capable realtime proxy in front — **Pushpin**
(self-hosted, open source) or **Fastly Fanout** — and have the app *publish* events to it while holding no
long-lived client connections itself. The proxy owns the open connections, so the service scales and deploys
like any stateless app. Treat the design below as the PoC tier and the proxy as the blessed production path.

**Keep-alives are mandatory.** Every stream emits a heartbeat comment (`: keep-alive\n\n`) at least every
**30 seconds**, whether the app or the proxy owns the connection. Idle SSE connections are silently dropped
by proxies and load balancers otherwise, and the heartbeat is how a dead client is detected. With a GRIP
proxy, configure its keep-alive; with the in-process design, the handler sends it on a 30-second timer.

## In-process `LISTEN/NOTIFY` (PoC / low-concurrency tier)

A single shared asyncpg connection issues `LISTEN`; on each `NOTIFY` it fans the event id to every subscriber's
`asyncio.Queue`. Each `EventSourceResponse` backfills from the events table (`WHERE id > :last_seen`) before going live,
so `Last-Event-ID` resumes exactly after the last delivered event. This is the PoC/<100-concurrent-streams design — see
the scaling caveat above before reaching for it in production.

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

    # ping=30 → sse-starlette emits a `: ping\n\n` comment every 30s. This keep-alive is MANDATORY, not optional.
    return EventSourceResponse(gen(), ping=30)
```

Key points: keep the NOTIFY payload small (send the event **id**, fetch the row in the handler — payloads have a size
limit); the listener connection lives **outside** the SQLAlchemy pool; and use sortable ids (ULIDs) so `WHERE id >
:last_seen ORDER BY id` is a correct, index-friendly backfill. The **30-second keep-alive is mandatory** —
`EventSourceResponse(..., ping=30)` (or send your own `: keep-alive\n\n` comment on a 30s timer); idle streams without
it get silently dropped by proxies and load balancers. Test subscribe → mutate → assert-frame, and
reconnect-with-`Last-Event-ID` → later-events-only.

## Production: publish to a GRIP proxy (Pushpin / Fastly Fanout)

At scale the app must not hold the connections itself. Put a **GRIP**-capable proxy (Pushpin self-hosted, or Fastly
Fanout) in front and invert the flow: the proxy terminates the client's SSE connection, the app's `/events` handler
responds **once** with GRIP *hold* instructions, and new events are *published* over the proxy's control plane instead
of streamed from the handler.

The shape:

- The `/events` handler returns an empty body plus GRIP headers — `Grip-Hold: stream` and `Grip-Channel: <channel>`
  — telling the proxy to hold the connection open and subscribe it to that channel. The handler then returns
  immediately; no `asyncio.Queue`, no long-lived connection in the app.
- On each domain write, the app **publishes** the SSE frame to the proxy's publish endpoint (Pushpin's
  `POST http://pushpin:5561/publish/`, or the Fastly Fanout publish API) on the matching channel. The proxy fans it
  out to every held connection.
- Configure the proxy's keep-alive (Pushpin sends a periodic keep-alive on held streams) so the mandatory 30-second
  heartbeat still reaches clients — the proxy owns it now, not the handler.

Because the app holds no streams, it scales and deploys like any stateless service: a rolling deploy no longer drops
every subscriber, and `LISTEN` load on Postgres no longer multiplies with instance count.
