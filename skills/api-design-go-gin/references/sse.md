# Server-Sent Events over Postgres LISTEN/NOTIFY

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

When the contract has an event-stream endpoint (`GET /events` returning `text/event-stream`), implement it with Postgres
`LISTEN/NOTIFY` as the broker — no extra message bus. One process-wide goroutine holds a dedicated `LISTEN` connection
and fans events out to every connected client over channels; each connection backfills missed events from a cursor, then
streams live. **This in-process design is the PoC / under-100-concurrent-streams tier** — see the scaling caveat above
and the GRIP-proxy production path at the end of this file.

SSE (not WebSockets) is the right tool here: it's one-directional server→client, runs over plain HTTP, and has built-in
reconnect + resume via the `Last-Event-ID` header. Use sortable IDs (ULIDs) as the cursor so "events after X" is a
simple `WHERE id > $1` and de-duplication is a lexical comparison.

## The publish side

On every committed write, emit a notification **inside the same transaction** as the event append, carrying the event id
as the payload:

```sql
-- name: NotifyEvent :exec
SELECT pg_notify('app_events', $1);  -- $1 = event id
```

Doing it in-transaction means a notification is only delivered if the write actually commits.

## The hub: one LISTEN connection, fan out to channels

The `LISTEN` connection must be a **standalone `pgx.Conn`**, opened directly — _not_ taken from the request pool — so a
long-lived listener never starves request handlers of a pooled connection.

```go
type Hub struct {
    store      *store.Store
    connString string
    log        *slog.Logger

    mu   sync.Mutex
    subs map[chan sseEvent]struct{}
}

func (h *Hub) Start(ctx context.Context) error {
    conn, err := h.acquireListening(ctx) // pgx.Connect + "LISTEN app_events"; fail fast at boot
    if err != nil {
        return err
    }
    go h.run(ctx, conn)
    return nil
}

func (h *Hub) run(ctx context.Context, conn *pgx.Conn) {
    for {
        n, err := conn.WaitForNotification(ctx)
        if err != nil {
            // Close on a non-cancellable derivative so teardown isn't skipped when
            // ctx is the thing that was just cancelled.
            closeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
            _ = conn.Close(closeCtx)
            cancel()
            if ctx.Err() != nil {
                return
            }
            conn, err = h.reacquire(ctx) // reconnect loop with backoff
            if err != nil {
                return
            }
            continue
        }
        ev, ok, err := h.store.GetEvent(ctx, n.Payload) // payload is the event id
        if err != nil || !ok {
            continue
        }
        if se, err := toSSEEvent(ev); err == nil {
            h.broadcast(se)
        }
    }
}
```

Fan out non-blocking, dropping for slow consumers (the client recovers via resume):

```go
func (h *Hub) broadcast(ev sseEvent) {
    h.mu.Lock()
    defer h.mu.Unlock()
    for ch := range h.subs {
        select {
        case ch <- ev:
        default: // slow consumer: drop rather than stall the whole fan-out
        }
    }
}

func (h *Hub) subscribe() chan sseEvent {
    ch := make(chan sseEvent, 64) // buffered: absorb bursts
    h.mu.Lock()
    h.subs[ch] = struct{}{}
    h.mu.Unlock()
    return ch
}

func (h *Hub) unsubscribe(ch chan sseEvent) {
    h.mu.Lock()
    if _, ok := h.subs[ch]; ok {
        delete(h.subs, ch)
        close(ch)
    }
    h.mu.Unlock()
}
```

## The connection handler: subscribe → backfill → live

Subscribe **before** writing headers so events arriving during backfill are captured in the channel and not lost. Then
backfill from `Last-Event-ID`, then stream live, de-duplicating against what the backfill already sent.

```go
func (a *App) streamEvents(c *gin.Context) {
    ctx := c.Request.Context()
    sub := a.Hub.subscribe()
    defer a.Hub.unsubscribe(sub)

    w := c.Writer
    w.Header().Set("Content-Type", "text/event-stream")
    w.Header().Set("Cache-Control", "no-cache")
    w.Header().Set("Connection", "keep-alive")
    w.Header().Set("X-Accel-Buffering", "no") // disable proxy buffering
    w.WriteHeader(http.StatusOK)
    w.Flush()

    // Backfill events strictly after Last-Event-ID, paging until a short page so a
    // resume spanning many events leaves no gap. Empty header → live only.
    const pageSize = 1000
    cursor := c.GetHeader("Last-Event-ID")
    for cursor != "" {
        events, err := a.Store.EventsAfter(ctx, cursor, pageSize)
        if err != nil {
            break
        }
        for _, ev := range events {
            cursor = ev.ID
            if se, err := toSSEEvent(ev); err == nil {
                writeSSEFrame(w, se)
            }
        }
        w.Flush()
        if len(events) < pageSize {
            break
        }
    }

    // Mandatory heartbeat: a ": keep-alive" comment at least every 30s keeps proxies
    // and load balancers from silently dropping an idle stream, and surfaces dead clients.
    keepAlive := time.NewTicker(30 * time.Second)
    defer keepAlive.Stop()

    for {
        select {
        case ev, ok := <-sub:
            if !ok {
                return
            }
            if cursor != "" && ev.ID <= cursor { // already delivered by backfill
                continue
            }
            writeSSEFrame(w, ev)
            w.Flush()
        case <-keepAlive.C: // mandatory 30s heartbeat
            _, _ = io.WriteString(w, ": keep-alive\n\n")
            w.Flush()
        case <-ctx.Done(): // client disconnected
            return
        }
    }
}

func writeSSEFrame(w io.Writer, ev sseEvent) {
    // Data is compact JSON (no embedded newlines) → a single data: line is safe.
    _, _ = fmt.Fprintf(w, "id: %s\nevent: %s\ndata: %s\n\n", ev.ID, ev.Name, ev.Data)
}
```

## Gotchas

- **Flush after every write** — SSE is useless if buffered. `gin`'s `c.Writer` implements `http.Flusher`; call
  `w.Flush()`. Disable proxy buffering with `X-Accel-Buffering: no` (nginx) and ensure no gzip middleware sits in front
  of the stream.
- **No write timeout on the streaming route.** A global `WriteTimeout` will kill long-lived SSE connections; configure
  timeouts so the stream route is exempt (or use per-handler deadlines).
- **Subscribe before headers**, backfill from the durable log, then live — that ordering is what guarantees no event is
  dropped across the live/replay seam.
- **The cursor is the event id.** Because IDs sort in creation order (ULID), "after this id" is `WHERE id > $1` and
  "already sent" is `ev.ID <= cursor` — no timestamps, no sequence table.
- **Reconnect resilience**: the hub reconnects its `LISTEN` conn with backoff; clients reconnect automatically and send
  `Last-Event-ID`, so a dropped notification during a blip is recovered from the log on the next connection.
- **Keep-alive is mandatory, not optional.** The 30-second `: keep-alive` ticker above is required — without it,
  intermediaries drop idle connections and dead clients go undetected. Never ship the stream without it.

## Production: publish to a GRIP proxy (Pushpin / Fastly Fanout)

The in-process hub above is the PoC tier. For production or anything user-facing at scale, **stop holding connections in
the app** and front the SSE endpoint with a GRIP-capable realtime proxy — **Pushpin** (self-hosted, open source) or
**Fastly Fanout** (managed). The proxy owns every long-lived client connection; the app becomes stateless and scales and
deploys like any other HTTP service.

The mechanism is **GRIP** (Generic Realtime Intermediary Protocol):

- The client's SSE request hits the proxy, which forwards it to your `GET /events` handler. The handler does its
  backfill, then responds with **GRIP hold instructions** instead of streaming: it sets `Content-Type: text/event-stream`
  and a `Grip-Hold: stream` header naming a channel (e.g. `Grip-Channel: events`), and returns. The proxy holds the
  connection open and subscribed to that channel.
- When an event commits, the app **publishes** it to the proxy's control plane — Pushpin's publish endpoint
  (`POST http://pushpin:5561/publish/`) or the Fastly Fanout publish API — addressed to the same channel, formatted as
  an SSE frame. The proxy fans it out to every held connection. The app holds **no** long-lived client connections.
- Configure the **30-second keep-alive on the proxy** (Pushpin sends a keep-alive comment per channel on a configurable
  interval; set it to ≤30s) instead of the in-process ticker.

The Postgres event log and `Last-Event-ID` backfill stay exactly as above — only the live fan-out moves from in-process
channels to the proxy. A full Pushpin config is out of scope here; the load-bearing pieces are the names: **GRIP**,
`Grip-Hold`, `Grip-Channel`, and the proxy's **publish endpoint**.
