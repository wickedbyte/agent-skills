# Observability & deployment

Liveness/readiness probes, structured logging, and the container/compose skeleton that runs the service. All examples
assume `best-practices-python` style and the uv toolchain.

## Probes: two audiences & structured logging

**Two probes, two audiences.** `/readyz` answers "can I serve traffic right now?" for the load balancer and
readiness gate — a shallow dependency check (a `SELECT 1`-class ping), 200 or 503, and it stays **open**
(the balancer carries no token). `/healthz` answers "am I healthy?" with a richer report — component and
dependency status, build/version — meant for operators and dashboards. Because that detail leaks internal
topology, **`/healthz` sits behind authentication**, not in the always-open set. Keep `/openapi.json` open.
If an orchestrator needs a liveness check, point it at an open, bodyless `/livez` (or reuse `/readyz`) that
returns 200 — never expose the detailed `/healthz` publicly.

In FastAPI terms: register `/readyz` and `/livez` (and `/openapi.json`) outside the auth gate, and mount `/healthz`
on a router that carries the same `Depends(require_auth)` gate as the business routers (see
`references/bootstrap-and-config.md`). The `ping` lives on the store so the readiness check goes through the same pool
a real request would:

```python
# store/event_store.py
from sqlalchemy import text

class EventStore:
    async def ping(self) -> None:
        async with self._session_factory() as session:
            await session.execute(text("SELECT 1"))
```

Log **structured JSON to stdout** — let the platform handle shipping and rotation; never write log files from the app.
Use `structlog` (or stdlib `logging` with a JSON formatter) configured once at startup, bind a request id via
middleware, and emit one event per request. Two rules that are really one: **never log secrets** — Authorization
headers, bearer tokens, raw request bodies that may carry credentials — and on a 500, log the exception server-side
(with a stack trace and the request id) while the client receives only the opaque error envelope. The log is for you;
the envelope is for them. Do **not** unit-test log lines (see `references/testing.md`).

## The container & compose skeleton

- **`Dockerfile`** — multi-stage on the `ghcr.io/astral-sh/uv` image: `uv sync --frozen --no-dev` into a venv, copy the
  source, drop to a non-root user, `ENTRYPOINT ["python", "-m", "<pkg>.main"]`. Pull the **current** uv base image tag;
  don't hardcode one from memory.
- **`compose.yaml`** — the app plus its own `postgres` (and `valkey` if you use it), with a one-shot `migrate` service
  (`depends_on: postgres: condition: service_healthy`) that the app waits on via
  `condition: service_completed_successfully`.
