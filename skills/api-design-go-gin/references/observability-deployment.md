# Observability & Deployment

The cross-cutting concerns that make an API operable: structured logs, health/readiness probes, and a small, secure
container image.

## Structured logging with `slog`

Use `log/slog` (stdlib) to emit **JSON to stdout**, initialized once in `main` and set as the default so every package
logs through it:

```go
logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
slog.SetDefault(logger)
```

Log structured key/values, not interpolated strings, so logs stay queryable:

```go
slog.Info("listening", "addr", srv.Addr)
slog.Error("unhandled request error", "error", err.Error(), "path", c.FullPath())
```

Rules:

- **Never log secrets or tokens.** Don't log `Authorization` headers, JWTs, or full request bodies that may carry PII.
  Log ids and outcomes, not credentials.
- **Log the cause of a 500, expose nothing.** The unknown-error path logs the real error and returns the generic
  envelope (see `errors.md`).
- **Don't unit-test logging** — assert behavior, not log lines.

## Health & readiness probes

**Two probes, two audiences.** `/readyz` answers "can I serve traffic right now?" for the load balancer and
readiness gate — a shallow dependency check (a `SELECT 1`-class ping), 200 or 503, and it stays **open**
(the balancer carries no token). `/healthz` answers "am I healthy?" with a richer report — component and
dependency status, build/version — meant for operators and dashboards. Because that detail leaks internal
topology, **`/healthz` sits behind authentication**, not in the always-open set. Keep `/openapi.json` open.
If an orchestrator needs a liveness check, point it at an open, bodyless `/livez` (or reuse `/readyz`) that
returns 200 — never expose the detailed `/healthz` publicly.

So there are three meta endpoints with two audiences:

- **`/livez` (liveness, open)** — the process is up. Return 200 unconditionally and bodyless; a failure here tells an
  orchestrator to restart the pod.
- **`/readyz` (readiness, open)** — the process can serve traffic, i.e. dependencies are reachable. Ping the pool; 503
  if not. A failure here tells the load balancer to stop routing, without restarting. Keep it **shallow** — one pool
  ping, no detail in the body.
- **`/healthz` (detailed health, gated)** — a richer report (pool status, dependency checks, build/version) for
  operators and dashboards. It sits **behind the auth gate** because that detail leaks internal topology; register it
  inside the authed group, not with the open meta routes.

```go
func livez(c *gin.Context) { c.Status(http.StatusOK) } // liveness: always 200, bodyless, open

func (a *App) readyz(c *gin.Context) { // readiness: shallow pool ping, open
    ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
    defer cancel()
    if err := a.Store.Pool().Ping(ctx); err != nil { // DB unreachable → not ready
        c.Status(http.StatusServiceUnavailable)
        return
    }
    c.Status(http.StatusOK)
}

// healthz is registered INSIDE the authed group — it returns a detailed report,
// so it must not be reachable without a token when the gate is on.
func (a *App) healthz(c *gin.Context) {
    ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
    defer cancel()
    status := "ok"
    db := "ok"
    if err := a.Store.Pool().Ping(ctx); err != nil {
        status, db = "degraded", "unreachable"
    }
    c.JSON(http.StatusOK, gin.H{
        "status":  status,
        "db":      db,
        "version": a.BuildVersion, // build/version metadata for operators
        "commit":  a.BuildCommit,
    })
}
```

Wire `/readyz` and `/livez` (plus `/openapi.json`) as open meta routes; register `/healthz` inside the authed group.
See `routing-and-rpc.md` for the router wiring and `auth-oauth2.md` for the open-paths set.

## Dockerfile — multi-stage, static, distroless

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download              # cache deps separately from source
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/server /server
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

`CGO_ENABLED=0` produces a static binary that runs on `distroless/static` (no libc, no shell) — minimal attack surface.
Use the floating `golang:alpine` tag and let `GOTOOLCHAIN=auto` fetch the exact patch your `go.mod` declares, so the
image tracks the language version you actually target rather than a pinned one.
