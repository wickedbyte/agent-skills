# Server-Sent Events & Live Streaming

SSE is the simplest way to push server→client updates over plain HTTP: a long-lived `text/event-stream` response of
`id:`/`event:`/`data:` frames, with automatic browser reconnection that replays the last seen id via the
`Last-Event-ID` header. Axum has first-class support (`axum::response::sse`). For server-pushed events that originate
in the database, the clean architecture is **Postgres `LISTEN/NOTIFY` → one listener task → a `tokio::broadcast`
channel → many SSE connections.**

## The fan-out architecture

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

    Sse::new(stream).keep_alive(KeepAlive::default())  // periodic comments keep proxies from closing idle conns
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
append order (see the monotonic ULID generator in `project-structure.md`). Test it: subscribe, mutate, assert the
frames; reconnect with a `Last-Event-ID` and assert only later events arrive (see `testing.md`).
