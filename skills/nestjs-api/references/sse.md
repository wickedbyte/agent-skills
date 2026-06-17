# Server-Sent Events via Postgres `LISTEN/NOTIFY`

The event stream is a single `GET /events` endpoint returning `text/event-stream`. NestJS exposes SSE through `@Sse()`,
which expects an RxJS `Observable<MessageEvent>`. The transport is Postgres `LISTEN/NOTIFY`: on every event append the
writer issues `NOTIFY`, a dedicated listening connection fans those out to a `Subject`, and each subscriber gets a
per-connection stream that **backfills** from the events table (for `Last-Event-ID` resume) and then goes **live**.

## The controller is trivial

```ts
@Controller()
export class EventsController {
    constructor(private readonly hub: EventHub) {}

    @Sse("events")
    events(@Headers("last-event-id") lastEventId?: string): Observable<MessageEvent> {
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
        case "TaskCaptured": return "task.created";
        case "TaskTitleChanged":
        case "TaskNotesChanged": return "task.updated";
        case "TaskCompleted": return "task.completed";
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
        const client = new Client({ connectionString: this.config.databaseUrl });
        client.on("notification", (msg) => {
            // chain onto a promise so notifications are handled in commit order, not interleaved
            this.notifyQueue = this.notifyQueue.then(() =>
                this.onNotify(msg.payload).catch((err: unknown) => this.logger.error("sse notify failed", err)),
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
stream(lastEventId: string | null): Observable<MessageEvent> {
    const live$ = this.subject.asObservable();
    if (lastEventId === null) return live$; // no resume → live only

    let lastBackfilled = lastEventId;
    const backfill$ = defer(() => from(this.backfill(lastEventId))).pipe(
        concatMap((frames) => from(frames)),
        tap((frame) => { if (frame.id !== undefined && frame.id > lastBackfilled) lastBackfilled = frame.id; }),
    );
    const dedupedLive$ = live$.pipe(
        filter((frame) => frame.id === undefined || frame.id > lastBackfilled),
    );
    return merge(backfill$, dedupedLive$);
}

private async backfill(lastEventId: string): Promise<MessageEvent[]> {
    const events = await this.store.eventsAfter(lastEventId); // WHERE id > :lastEventId ORDER BY id
    return events.map(toFrame);
}
```

- **`eventsAfter` uses `id > :lastSeen ORDER BY id`** — this is why ids must sort by creation order (ULID), so a
  lexicographic `>` means "strictly later".
- **Dedup window.** A live frame that arrives while backfill is still draining could already be in the backfill set;
  dropping `id <= lastBackfilled` from the live stream removes the overlap. Without it, a client reconnecting at a busy
  moment sees a few events twice.
- **No resume → live only.** A first connection with no `Last-Event-ID` just observes the `Subject`; it should not
  replay history.

## What to test

- **Live delivery (I20):** subscribe, mutate, assert frames arrive with `id` = event id, the mapped `event:` name, and
  the right payload.
- **Resume:** read some frames, capture the last id, reconnect with `Last-Event-ID`, mutate again, assert the resumed
  stream contains only **later** events and **none** of the already-seen ids.

SSE tests are timing-sensitive; give the subscriber a moment to attach before mutating, and read a bounded number of
frames so the test terminates. See `references/testing.md` for the frame-reader helper.

## Notes

- **Flush per frame, no buffering.** The Fastify adapter handles SSE framing for `@Sse()`; don't wrap the route in a
  compression middleware that buffers, or frames will be delayed.
- **One default stream.** `/events` carries both task and project events; the `event:` name distinguishes them. A client
  filters by name.
- **Heartbeats** (a comment line every N seconds) are optional but help keep idle connections and proxies alive; add one
  if your deployment terminates idle connections.
