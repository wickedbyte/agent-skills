# Project Structure

This layout is the default for new work; adapt to an existing project's conventions rather than restructuring it.

How to lay out the module — one package per concern, dependencies pointing inward — so the pure core stays isolated from
the HTTP, database, and auth adapters.

## Module layout

Use `internal/` so nothing leaks as a public API of the module, one package per concern, and `cmd/<binary>` for
entrypoints:

```
yourapi/
  go.mod  go.sum
  Makefile  Dockerfile  compose.yaml
  .golangci.yml  sqlc.yaml
  migrations/                  # goose SQL (embedded via //go:embed)
  cmd/
    server/main.go             # the only place that wires concrete dependencies
    seed/main.go               # optional one-shot jobs
  internal/
    config/config.go           # env → typed Config
    domain/                    # pure core (decide/apply + types); imports only stdlib
    store/                     # pgx adapter
      db/                      # sqlc-generated — DO NOT EDIT
      queries/*.sql
    httpapi/                   # Gin layer
    auth/auth.go               # OAuth2 resource-server middleware
    openapi/                   # embed + serve the canonical spec
    testsupport/               # shared test helpers (testcontainers, etc.)
```

**Dependency direction is inward and acyclic:** `cmd → httpapi → store → domain`; `auth` and `openapi` are leaves.
`domain` never imports `gin`, `pgx`, or `store`. If you find yourself importing `gin` into `domain`, the logic is in the
wrong layer.
