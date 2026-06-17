# Server-Sent Events via Postgres `LISTEN/NOTIFY`

**Scaling caveat — read before you build.** The in-process `LISTEN/NOTIFY` fan-out shown below holds one
long-lived connection per subscriber inside the app process. That is fine for a proof of concept or a
low-concurrency internal tool — roughly **under 100 concurrent streams on a single instance** — but it does
**not** scale: open connections pin memory and file descriptors to specific instances, every deploy drops
every stream, and horizontal scaling multiplies the `LISTEN` load on Postgres. **For production, or anything
user-facing at scale, do not fan out from the app.** Put a GRIP-capable realtime proxy in front — **Pushpin**
(self-hosted, open source) or **Fastly Fanout** — and have the app _publish_ events to it while holding no
long-lived client connections itself. The proxy owns the open connections, so the service scales and deploys
like any stateless app. Treat the design below as the PoC tier and the proxy as the blessed production path.

**Keep-alives are mandatory.** Every stream emits a heartbeat comment (`: keep-alive\n\n`) at least every
**30 seconds**, whether the app or the proxy owns the connection. Idle SSE connections are silently dropped
by proxies and load balancers otherwise, and the heartbeat is how a dead client is detected. With a GRIP
proxy, configure its keep-alive; with the in-process design, the handler sends it on a 30-second timer.

## The PoC tier: in-process `LISTEN/NOTIFY`

The event stream is a single `GET /events` endpoint returning `text/event-stream`. NestJS exposes SSE through `@Sse()`,
which expects an RxJS `Observable<MessageEvent>`. The transport is Postgres `LISTEN/NOTIFY`: on every event append the
writer issues `NOTIFY`, a dedicated listening connection fans those out to a `Subject`, and each subscriber gets a
per-connection stream that **backfills** from the events table (for `Last-Event-ID` resume) and then goes **live**.
This is the **PoC / low-concurrency tier** (under ~100 concurrent streams on one instance); see _Production: publish to
a GRIP proxy_ below for the path that scales.

## The controller is trivial

```ts
@Controller()
export class EventsController {
    constructor(private readonly hub: EventHub) {}

    @Sse("events")
    events(
        @Headers("last-event-id") lastEventId?: string,
    ): Observable<MessageEvent> {
        return this.hub.stream(lastEventId ?? null);
    }
}
```

`@Sse()` sets the `Content-Type`, keeps the connection open, and serializes each emitted `MessageEvent` into a frame.
The header name is `last-event-id` (browsers send it automatically on reconnect; a client resuming manually sets it).

## The frame contract

Each frame carries the **domain event id** as its `id:` (so resume is exact), a mapped event **name**, and a JSON
`data` payload:

```
id: event_01J9Z…
event: task.completed
data: {"taskId":"task_…","completedAt":"2026-06-15T21:45:00Z"}

```

`id = event id` is the invariant that makes `Last-Event-ID` resume strictly after a known point. The event **name** is a
fixed domain→wire mapping (`TaskCaptured → task.created`, `TaskCompleted → task.completed`, …); keep it in one pure
function and unit-test it:

```ts
export function sseEventName(type: EventData["type"]): string {
    switch (type) {
        case "TaskCaptured":
            return "task.created";
        case "TaskTitleChanged":
        case "TaskNotesChanged":
            return "task.updated";
        case "TaskCompleted":
            return "task.completed";
        // …one arm per event; exhaustive…
    }
}
```

A `toFrame(event)` helper builds the `MessageEvent` (`{ id, type, data }`) from a `DomainEvent`, attaching the stream id
under the right key (`taskId` vs `projectId`).

## The hub — one listener, many subscribers

A single injectable holds one dedicated `pg` `Client` doing `LISTEN`, and a `Subject` that every subscriber observes.
It implements the lifecycle hooks so the listener connects on boot and closes on shutdown.

```ts
@Injectable()
export class EventHub implements OnApplicationBootstrap, OnApplicationShutdown {
    private readonly subject = new Subject<MessageEvent>();
    private client: Client | null = null;
    private shuttingDown = false;
    private notifyQueue: Promise<void> = Promise.resolve(); // serialize NOTIFY handling

    async onApplicationBootstrap(): Promise<void> {
        await this.connectListener();
    }

    async onApplicationShutdown(): Promise<void> {
        this.shuttingDown = true;
        await this.client?.end().catch(() => undefined);
        this.subject.complete();
    }

    private async connectListener(): Promise<void> {
        const client = new Client({
            connectionString: this.config.databaseUrl,
        });
        client.on("notification", (msg) => {
            // chain onto a promise so notifications are handled in commit order, not interleaved
            this.notifyQueue = this.notifyQueue.then(() =>
                this.onNotify(msg.payload).catch((err: unknown) =>
                    this.logger.error("sse notify failed", err),
                ),
            );
        });
        client.on("error", (err: unknown) => {
            this.logger.error("sse listener error", err);
            client.removeAllListeners();
            void client.end().catch(() => undefined);
            if (!this.shuttingDown) this.scheduleReconnect();
        });
        await client.connect();
        await client.query(`LISTEN ${NOTIFY_CHANNEL}`);
        this.client = client;
    }

    private async onNotify(payload: string | undefined): Promise<void> {
        if (!payload) return;
        const event = await this.store.getEvent(payload); // payload is the event id
        if (event !== null) this.subject.next(toFrame(event));
    }
}
```

Design points:

- **One dedicated `Client`, not a pooled connection.** `LISTEN` is connection-scoped and long-lived; it must not be a
  pool connection that gets reused for queries.
- **The NOTIFY payload is the event id, not the event.** Postgres `NOTIFY` payloads are capped (~8000 bytes); send the
  id and let `onNotify` fetch the row. This also keeps ordering authoritative (the table, not the payload).
- **Serialize notify handling** through `notifyQueue` so concurrent notifications are processed in commit order and the
  `Subject` emits in a stable sequence.
- **Reconnect on error.** A dropped listener must reconnect (with backoff) or the stream silently goes dead; gate it on
  `shuttingDown` so shutdown doesn't trigger a reconnect loop.

## Per-connection stream: backfill, then live, with dedup

The crux of correct resume. When a subscriber sends `Last-Event-ID`, you must replay events **strictly after** that id
from the table, then merge in the live feed — without duplicating any event that appears in both:

```ts
// A comment-only MessageEvent renders as `: keep-alive\n\n` — no `id`/`event`, so it never
// disturbs Last-Event-ID resume or the dedup window.
const KEEP_ALIVE_MS = 30_000;
const keepAlive$: Observable<MessageEvent> = interval(KEEP_ALIVE_MS).pipe(
    map(() => ({ type: "comment", data: "keep-alive" }) as MessageEvent),
);

stream(lastEventId: string | null): Observable<MessageEvent> {
    const live$ = this.subject.asObservable();
    // Heartbeat is mandatory, not optional: merge it into every stream so idle
    // connections survive proxies/load balancers and dead clients are detected.
    if (lastEventId === null) return merge(live$, keepAlive$); // no resume → live + keep-alive

    let lastBackfilled = lastEventId;
    const backfill$ = defer(() => from(this.backfill(lastEventId))).pipe(
        concatMap((frames) => from(frames)),
        tap((frame) => { if (frame.id !== undefined && frame.id > lastBackfilled) lastBackfilled = frame.id; }),
    );
    const dedupedLive$ = live$.pipe(
        filter((frame) => frame.id === undefined || frame.id > lastBackfilled),
    );
    return merge(backfill$, dedupedLive$, keepAlive$);
}

private async backfill(lastEventId: string): Promise<MessageEvent[]> {
    const events = await this.store.eventsAfter(lastEventId); // WHERE id > :lastEventId ORDER BY id
    return events.map(toFrame);
}
```

The `interval(30_000)` keep-alive is part of the contract, not a deployment tweak — never ship the in-process stream
without it.

- **`eventsAfter` uses `id > :lastSeen ORDER BY id`** — this is why ids must sort by creation order (ULID), so a
  lexicographic `>` means "strictly later".
- **Dedup window.** A live frame that arrives while backfill is still draining could already be in the backfill set;
  dropping `id <= lastBackfilled` from the live stream removes the overlap. Without it, a client reconnecting at a busy
  moment sees a few events twice.
- **No resume → live (plus keep-alive).** A first connection with no `Last-Event-ID` just observes the `Subject` (merged
  with the heartbeat); it should not replay history.

## Production: publish to a GRIP proxy

The in-process design above does not scale (see the caveat at the top). For production, put a **GRIP**-capable realtime
proxy in front — **Pushpin** (self-hosted, open source) or **Fastly Fanout** — and stop holding connections in the app:

- **The proxy owns the open connections.** Clients connect to the proxy; the proxy forwards the initial `GET /events`
  request to the app over its control plane.
- **The app responds with GRIP hold instructions, then returns.** Instead of streaming, the handler answers with
  `Grip-Hold: stream` and a `Grip-Channel: events` header (and any backfill body), then the request _completes_ — the app
  holds no socket. The proxy keeps the client connection open, subscribed to that channel.
- **The app publishes events to the proxy's publish endpoint.** When a domain event appends, publish the SSE frame to the
  proxy (Pushpin's `POST /publish/` HTTP control API, or the Fanout publish API) on the `events` channel; the proxy fans
  it out to every held connection. The app is now stateless: any instance can publish, deploys drop no streams, and
  horizontal scaling no longer multiplies `LISTEN` load.
- **Configure the proxy's keep-alive.** Set the proxy to emit the `: keep-alive` heartbeat at least every 30 s (e.g.
  Pushpin's `keep-alive` field on the hold) so the mandatory-heartbeat rule still holds when the proxy owns the socket.

The `LISTEN/NOTIFY` → domain-event pipeline can still feed the publisher; what changes is that the app _publishes_ each
frame to the GRIP proxy instead of pushing it down a held `@Sse()` connection. Name the mechanism in code and config —
GRIP, `Grip-Hold`, `Grip-Channel`, the publish endpoint — so the deployment is explicit.

## What to test

- **Live delivery (I20):** subscribe, mutate, assert frames arrive with `id` = event id, the mapped `event:` name, and
  the right payload.
- **Resume:** read some frames, capture the last id, reconnect with `Last-Event-ID`, mutate again, assert the resumed
  stream contains only **later** events and **none** of the already-seen ids.
- **Keep-alive:** assert a `: keep-alive` comment frame is emitted on the 30 s timer (drive it with fake timers so the
  test doesn't wait 30 seconds) and that it carries no `id`/`event`, so it never affects resume or dedup.

SSE tests are timing-sensitive; give the subscriber a moment to attach before mutating, and read a bounded number of
frames so the test terminates. See `references/testing.md` for the frame-reader helper.

## Notes

- **Flush per frame, no buffering.** The Fastify adapter handles SSE framing for `@Sse()`; don't wrap the route in a
  compression middleware that buffers, or frames will be delayed.
- **One default stream.** `/events` carries both task and project events; the `event:` name distinguishes them. A client
  filters by name.
- **Heartbeats are mandatory, every 30 s.** The `keepAlive$` merge above emits a `: keep-alive` comment frame on a
  30-second timer on every stream — it is not optional and not deployment-dependent. Proxies and load balancers drop
  idle SSE connections, and the heartbeat is also how a dead client is detected.
