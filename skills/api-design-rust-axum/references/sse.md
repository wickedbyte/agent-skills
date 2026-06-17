# Server-Sent Events & Live Streaming

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

SSE is the simplest way to push server→client updates over plain HTTP: a long-lived `text/event-stream` response of
`id:`/`event:`/`data:` frames, with automatic browser reconnection that replays the last seen id via the
`Last-Event-ID` header. Axum has first-class support (`axum::response::sse`). For server-pushed events that originate
in the database, the PoC-tier architecture is **Postgres `LISTEN/NOTIFY` → one listener task → a `tokio::broadcast`
channel → many SSE connections.**

## The fan-out architecture (PoC / low-concurrency tier)

This in-process fan-out is the PoC/<100-concurrent-streams design. Past that, move to the GRIP proxy below.

```
write tx: INSERT event … ; SELECT pg_notify('events', '<event_id>')   (same transaction)
                                   │
            one background task: PgListener.recv() → fetch row → broadcast::Sender.send(record)
                                   │  (1 dedicated LISTEN connection for the whole process)
        each GET /events: broadcast::Receiver → filter/format → SSE frame to that client
```

- **One** dedicated `LISTEN` connection per process (not per client) feeds a `broadcast::Sender` held in `AppState`.
- Each SSE request `subscribe()`s to get a `Receiver`, backfills missed events from the DB, then streams live.
- `NOTIFY` is issued **inside the write transaction** (see `persistence.md`), so a notification never precedes the
  committed row.

## Publisher side (in the store)

```rust
// Issue NOTIFY on the same connection/transaction as the INSERT.
pub(super) async fn notify_event(conn: &mut PgConnection, event_id: &str) -> Result<(), StoreError> {
    sqlx::query!("SELECT pg_notify('taskflow_events', $1)", event_id).execute(conn).await?;
    Ok(())
}
```

## The listener task → broadcast

```rust
use sqlx::postgres::PgListener;
use tokio::sync::broadcast;

const CHANNEL: &str = "taskflow_events";

/// Spawned once from main: tokio::spawn(run_event_listener(store, events_sender)).
pub async fn run_event_listener(store: Store, events: broadcast::Sender<EventRecord>) {
    loop {
        if let Err(error) = listen_loop(&store, &events).await {
            tracing::error!(%error, "sse listener error; reconnecting");
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;  // reconnect with backoff
        }
    }
}

async fn listen_loop(store: &Store, events: &broadcast::Sender<EventRecord>) -> Result<(), sqlx::Error> {
    let mut listener = PgListener::connect_with(store.pool()).await?;
    listener.listen(CHANNEL).await?;
    loop {
        let notification = listener.recv().await?;          // payload = event id
        match store.fetch_event(notification.payload()).await {
            Ok(Some(record)) => { let _ = events.send(record); } // Err = no subscribers; clients resume via Last-Event-ID
            Ok(None) => {}
            Err(error) => tracing::error!(%error, "sse: failed to fetch notified event"),
        }
    }
}
```

`broadcast::Sender::send` returns `Err` only when there are zero receivers — harmless here, since a reconnecting
client recovers via `Last-Event-ID`. Size the channel (e.g. `broadcast::channel(1024)`) so a briefly-slow client
doesn't immediately lag; a client that overflows the buffer gets `RecvError::Lagged` and recovers by reconnecting.

## The SSE handler: backfill, then live

The subtle correctness points are (1) **subscribe before backfilling** so no event slips through the gap between the
two, (2) **page the backfill to the live edge** (one bounded query can miss events when many occurred before the
subscription), and (3) **dedupe** the live stream against what the backfill already delivered, using the sortable id
as the cursor.

```rust
use std::convert::Infallible;
use std::time::Duration;
use axum::response::sse::{Event, KeepAlive, Sse};
use futures_core::Stream;
use tokio::sync::broadcast::error::RecvError;

const BACKFILL_LIMIT: i64 = 1000;

pub(super) async fn stream_events(
    State(state): State<AppState>, headers: HeaderMap,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let mut rx = state.events.subscribe();          // (1) subscribe FIRST
    let store = state.store.clone();
    let last_event_id = headers.get("last-event-id")
        .and_then(|v| v.to_str().ok()).map(ToOwned::to_owned);

    let stream = async_stream::stream! {
        let mut cursor = last_event_id.clone();

        // (2) page the backlog until a short page reaches the live edge
        while let Some(after) = cursor.clone() {
            match store.events_after(&after, BACKFILL_LIMIT).await {
                Ok(records) => {
                    let full = i64::try_from(records.len()).is_ok_and(|n| n >= BACKFILL_LIMIT);
                    for record in records {
                        cursor = Some(record.id.clone());
                        yield Ok::<_, Infallible>(to_event(&record));
                    }
                    if !full { break; }
                }
                Err(error) => { tracing::error!(%error, "sse backfill failed"); break; }
            }
        }

        loop {
            match rx.recv().await {
                Ok(record) => {
                    // (3) skip anything the backfill already sent (id is the cursor)
                    if cursor.as_deref().is_some_and(|c| record.id.as_str() <= c) { continue; }
                    yield Ok::<_, Infallible>(to_event(&record));
                }
                Err(RecvError::Lagged(_)) => {}    // dropped frames; client resumes on reconnect
                Err(RecvError::Closed) => break,
            }
        }
    };

    // Mandatory 30s heartbeat: idle SSE connections are dropped by proxies/LBs otherwise, and the
    // comment is how a dead client is detected. Never omit this or leave it on the default interval.
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(30)))
}
```

`async_stream::stream!` lets you write the generator with `yield` (hand-writing a `Stream` impl is the alternative;
`gen` blocks are still unstable on Rust 1.96 — don't emit them). `Infallible` as the error type means the stream
never yields a transport error; per-event problems are logged and skipped.

## Building frames

Map the domain event type to the contract's SSE event name, set `id:` to the sortable event id (so `Last-Event-ID`
works), and put the payload in `data:`.

```rust
fn to_event(record: &EventRecord) -> Event {
    Event::default()
        .id(record.id.clone())               // enables Last-Event-ID resume
        .event(sse_name(&record.event_type)) // contract's event name, e.g. "task.completed"
        .data(build_data(record))            // JSON string payload
}

fn sse_name(event_type: &str) -> &'static str {
    match event_type {
        "TaskCaptured"  => "task.created",
        "TaskCompleted" => "task.completed",
        // … exhaustive mapping …
        _ => "message",
    }
}
```

## Reconnection contract

The resume guarantee clients rely on: after a drop, the browser sends `Last-Event-ID: <last id it saw>`, and the
server must deliver **strictly later** events — no gaps, no duplicates. The id-ordered backfill plus the
`record.id <= cursor` skip above provide exactly that, which is why event ids must be **monotonic** and sort in
append order (see the monotonic ULID generator in `domain-core.md`). Test it: subscribe, mutate, assert the
frames; reconnect with a `Last-Event-ID` and assert only later events arrive (see `testing.md`).

## Production: publish to a GRIP proxy (Pushpin / Fastly Fanout)

At production scale the app must **not** hold the open connections — a GRIP-capable realtime proxy (Pushpin,
self-hosted; or Fastly Fanout) does, and the app stays stateless so it scales and deploys like any other service.
The mechanism is **GRIP** (Generic Realtime Intermediary Protocol):

- **The client connects to the proxy**, which forwards the request to the app's `GET /events` endpoint.
- **The app responds with GRIP hold instructions** instead of streaming: a `Grip-Hold: stream` response header (plus
  `Grip-Channel: events` to subscribe the held connection to a channel) and an empty/short body. The proxy then holds
  the long-lived SSE connection open on the app's behalf — the app's handler returns immediately.
- **The app publishes events to the proxy's publish endpoint** (Pushpin's `POST http://<pushpin>:5561/publish/`, or
  Fanout's publish API) over the proxy's control plane. The same `LISTEN/NOTIFY` listener task is reused, but instead
  of `broadcast::Sender::send` to in-process receivers it POSTs each event to the proxy, which fans it out to every
  held connection on that channel.
- **Configure the proxy's keep-alive** to emit the `: keep-alive` comment every 30s (the mandatory heartbeat moves
  from the handler to the proxy config).

The backfill/`Last-Event-ID` resume logic is unchanged in shape — it just runs as a publish-and-hold exchange rather
than an in-process stream. A full Pushpin/Fanout config is out of scope here; the load-bearing decision is to publish
to the proxy rather than fan out from the app.
