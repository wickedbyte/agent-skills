---
name: go-gin-api
description: >-
    Use when building, scaffolding, or extending a REST and/or RPC HTTP API in Go with the Gin framework — especially
    when you are handed an OpenAPI (Swagger) description and must turn it into a running, tested service. Triggers for:
    laying out a Go API module (`cmd/`, `internal/`, domain/store/httpapi layering), choosing and pulling in
    dependencies (Gin, pgx/v5, sqlc, goose, golang-jwt, keyfunc, oklog/ulid, testify, testcontainers), wiring Gin
    routing including resource-action RPC custom methods (`POST /tasks/{id}:complete`), request binding/validation and
    JSON error envelopes, OAuth 2.0 resource-server bearer-token auth (JWT + JWKS, issuer/audience/scope checks),
    Postgres persistence with transactions and optimistic concurrency, Server-Sent Events, graceful shutdown, and
    testing the service against its OpenAPI contract (route-coverage + schema fuzzing + httptest + testcontainers). Use
    this even when the user does not say "idiomatic Go" or name Gin explicitly but is clearly building an HTTP API in Go.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# How to Build a REST/RPC API in Go with Gin

This skill is a **skeleton and a build sequence**. Given an OpenAPI 3.x description of a REST/RPC API, it tells you how
to organize the code, which dependencies to pull (and how to pull the _current_ versions), how to route, parse,
validate, persist, secure with OAuth 2.0, and how to prove the running service matches its contract — so the only thing
left to write is the business logic unique to your API.

It targets Go as it stands in **mid-2026** (modules with a pinned `toolchain`, `go.mod` `tool` directives, `log/slog`,
generics, `golangci-lint` v2). Follow it for any Go HTTP-API work.

## The One Idea

**A Go HTTP service is a thin, well-typed shell around a pure core.** Push all decision-making into a dependency-free
domain package (plain functions and types — no Gin, no `pgx`, no `context` plumbing for logic), and keep the outer
layers — Gin handlers, the database, auth — as _adapters_ that translate the wire and the database to and from domain
types. Dependencies point inward only: `httpapi → store → domain`, and `domain` imports nothing but the standard
library.

Three consequences shape everything below:

1. **The OpenAPI document is the source of truth, not your handlers.** Serve the canonical spec verbatim and write a
   test that your router's routes equal the spec's operations; let a schema fuzzer drive the running service against the
   spec. Never hand-maintain a second copy of the contract in annotations.
2. **Boundaries are where bugs live.** JSON bodies, query params, path params, JWT claims, and DB rows are all
   untrusted until validated/translated. Reject unknown fields, parse into typed values, and map every domain/DB error
   to one JSON error envelope with the right status code.
3. **Errors are values; handle them explicitly.** Wrap with `%w`, compare with `errors.Is`/`errors.As`, define sentinel
   and typed errors at package boundaries, and translate infrastructure errors (a Postgres unique-violation) into
   domain-meaningful ones (a version conflict → `409`).

## When to Use This Skill

Use it for any of:

- Scaffolding a new Go HTTP API, or adding endpoints to an existing Gin service.
- Implementing an OpenAPI/Swagger spec in Go (REST resources **and** RPC-style custom methods).
- Choosing the dependency set for a Go API and pulling current versions.
- Adding OAuth 2.0 / OIDC bearer-token protection, request validation, transactional persistence, SSE, or a contract
  test suite to a Go service.

If you are also writing non-API Go (CLIs, libraries), apply the same idioms (Sections below) but skip the HTTP-specific
references.

## Do Not Pin Versions — Pull and Verify the Latest

This skill names **no version numbers** on purpose. Ecosystems move; a pinned version in a guide is wrong within months.
Instead, when you add a dependency:

```bash
go get github.com/gin-gonic/gin@latest      # resolves and records the current release
go mod tidy                                  # prune + fill go.sum
go list -m -u all                            # show available upgrades
```

- Verify each resolved version against its release notes / changelog before relying on it; check for a **major-version
  bump** (the import path carries it, e.g. `pgx/v5`, `jwt/v5`, `keyfunc/v3`) — picking the wrong major silently pulls an
  API you didn't expect.
- Track **build/dev tools** (sqlc, goose, golangci-lint, gofumpt) as `tool` directives so they version with the module:
  `go get -tool github.com/sqlc-dev/sqlc/cmd/sqlc@latest`, then run them with `go tool sqlc generate`.
- Set the Go version honestly: `go mod edit -go=$(go version | awk '{print $3}' | sed 's/go//')` and let
  `GOTOOLCHAIN=auto` (the default) fetch the matching compiler. Confirm the latest stable Go before starting.

## The Dependency Set (pull current versions of each)

A deliberately small tree — lean on the standard library; add a dependency only when it earns its place.

| Concern                | Module (no version — `go get …@latest`)            | Why this one                                                                          |
| ---------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------- |
| HTTP router/framework  | `github.com/gin-gonic/gin`                         | Fast httprouter core, middleware, binding. Idiomatic, ubiquitous, low variance.       |
| Postgres driver + pool | `github.com/jackc/pgx/v5` (`/pgxpool`, `/pgconn`)  | Native protocol, `LISTEN/NOTIFY`, typed errors, connection pool. No `database/sql` tax.|
| Type-safe queries      | `github.com/sqlc-dev/sqlc` (tool)                  | Generates Go from SQL — compile-checked queries, no ORM, no runtime reflection.       |
| Migrations             | `github.com/pressly/goose/v3`                      | Versioned SQL migrations; embeddable; sqlc can read the schema straight from them.     |
| Validation             | `github.com/go-playground/validator/v10`           | Gin's binding validator; struct-tag field rules. (Plus manual decode for strict specs.)|
| IDs                    | `github.com/oklog/ulid/v2`                          | Sortable, URL-safe, time-ordered IDs; great as SSE/stream cursors.                     |
| JWT verification       | `github.com/golang-jwt/jwt/v5`                      | Standard JWT parsing/validation with algorithm allow-listing.                          |
| JWKS key resolution    | `github.com/MicahParks/keyfunc/v3`                 | Fetches + caches + rotates the authorization server's public keys for `jwt.Parse`.     |
| Logging                | `log/slog` (stdlib)                                 | Structured JSON logs, no dependency.                                                   |
| Tests                  | `github.com/stretchr/testify` + `net/http/httptest`| Assertions + in-process HTTP. Add `testcontainers-go/modules/postgres` for real DB.    |
| Lint / format          | `mvdan.cc/gofumpt` + `golangci-lint` v2 (tools)     | Stricter-than-gofmt formatting + an aggregated linter gate.                            |

Config is **stdlib only** (`os.Getenv` with defaults) — don't pull a config framework for a dozen env vars.

## Project Layout

A standard module: `cmd/` for entrypoints, `internal/` for everything else (so nothing is importable outside the
module), one package per concern.

```
yourapi/
  go.mod  go.sum
  Makefile  Dockerfile  compose.yaml
  .golangci.yml  sqlc.yaml
  migrations/                 # goose SQL, embedded
  cmd/
    server/main.go            # wire deps → migrate → pool → router → serve; graceful shutdown
  internal/
    config/config.go          # env → typed Config (stdlib)
    domain/                   # PURE core: types + decision functions; imports only stdlib
    store/                    # pgx adapter: queries, transactions, error translation
      db/                     # sqlc-generated (DO NOT EDIT)
      queries/*.sql           # hand-written SQL for sqlc
    httpapi/                  # Gin: router, handlers, DTOs, error mapping, SSE
    auth/auth.go              # OAuth2 resource-server middleware (JWT + JWKS)
    openapi/                  # embeds the canonical spec; serves it; coverage test
```

Keep handlers methods on one `App` struct that holds dependencies — no package-level globals, no service locator:

```go
type App struct {
    Store  *store.Store
    Logger *slog.Logger
    Auth   gin.HandlerFunc // nil → no gate (tests); set in production
    Now    func() time.Time // injectable clock for deterministic tests
}
```

Details — module setup, the `tool` directives, `golangci-lint` v2 config, the distroless `Dockerfile`, env config, and
graceful shutdown — are in **`references/project-structure.md`**.

## The Build Sequence

Implement an OpenAPI spec by walking outward from the pure core. Run the gate (below) after each step; do not advance
on red.

1. **Scaffold + tooling.** Module, `cmd/server` with a `/healthz` route, `golangci.yml`, `Dockerfile`, `Makefile`. Gate
   green on the skeleton.
2. **Schema + migrations + sqlc.** Translate the data model into goose migrations; write SQL queries; `go tool sqlc
   generate` the typed `store/db`. (`references/persistence.md`.)
3. **Domain core (TDD).** For each invariant/business rule in the spec, write a failing table test, then the pure
   function that satisfies it. No HTTP, no DB. This is where the real logic lives. (`references/persistence.md` covers
   the domain↔store seam.)
4. **REST handlers + DTOs + error envelope.** Bind requests, call the core, map results and errors to status codes.
   (`references/routing-and-rpc.md`, `references/parsing-and-validation.md`.)
5. **RPC custom methods.** Wire the `POST /resource/{id}:action` colon-dispatch. (`references/routing-and-rpc.md`.)
6. **Streaming (if specs an SSE/event endpoint).** (`references/streaming-sse.md`.)
7. **OAuth 2.0 gate.** Resource-server JWT/JWKS middleware behind a flag. (`references/auth-oauth2.md`.)
8. **Serve + contract-test the OpenAPI.** Serve the canonical doc; assert route coverage; run a schema fuzzer.
   (`references/testing-and-contract.md`.)

## Routing: REST and RPC Custom Methods

Build the engine explicitly (no `gin.Default()` — you choose the middleware), keep meta endpoints ungated, and put the
rest behind an optional auth group:

```go
func NewRouter(app *App) *gin.Engine {
    r := gin.New()
    r.Use(gin.Recovery())
    r.HandleMethodNotAllowed = true // 405 for known path + wrong method, not 404

    r.GET("/healthz", healthz)            // liveness — always open
    r.GET("/readyz", app.readyz)          // readiness — always open
    r.GET("/openapi.json", app.openapiDoc) // contract — always open

    api := r.Group("/")
    if app.Auth != nil {
        api.Use(app.Auth)
    }
    api.POST("/tasks", app.createTask)
    api.GET("/tasks/:taskId", app.getTask)
    api.POST("/tasks/:taskId", app.dispatchTaskCommand) // RPC: :taskId carries ":action"
    // …
    return r
}
```

**RPC custom methods** follow the resource-action convention (Google AIP-136): `POST /tasks/{id}:complete`. Gin's
`:taskId` wildcard stops at `/` but **includes** the literal `:`, so `c.Param("taskId")` yields `"01J…:complete"`.
Split it on the **last** colon and dispatch — a single unit-tested helper, no router hacks:

```go
func splitCommand(raw string) (id, command string, ok bool) {
    i := strings.LastIndex(raw, ":")
    if i < 0 || raw[:i] == "" || raw[i+1:] == "" {
        return "", "", false
    }
    return raw[:i], raw[i+1:], true
}
```

The full pattern — dispatcher, rejecting `GET`/`PATCH` on a command path with 405, and the routing contract test — is in
**`references/routing-and-rpc.md`**.

## Parsing & Validation: reject at the boundary

For specs with `additionalProperties: false`, Gin's default `ShouldBindJSON` is **not enough** — `encoding/json` ignores
unknown fields. Decode with `DisallowUnknownFields` and surface failures as `422`:

```go
func bindJSON(c *gin.Context, dst any) bool {
    dec := json.NewDecoder(c.Request.Body)
    dec.DisallowUnknownFields()
    if err := dec.Decode(dst); err != nil {
        respondError(c, http.StatusUnprocessableEntity, "validation_failed", err.Error(), nil)
        return false
    }
    return true
}
```

Use `validator/v10` struct tags (`binding:"required,max=200"`) for simple field rules, but encode **PATCH semantics**
(absent vs explicit-`null` vs value) with a small tri-state type, and convert wire strings into typed domain values
(dates, enums) in a `toCommand()` method — not in the handler. Every failure becomes the same envelope. See
**`references/parsing-and-validation.md`**.

## The Error Envelope

One shape for every error, one function that maps domain/store errors to it:

```go
func handleError(c *gin.Context, err error) {
    var verr *domain.ValidationError
    if errors.As(err, &verr) {
        respondError(c, http.StatusUnprocessableEntity, "validation_failed", verr.Error(), verr.Details())
        return
    }
    if errors.Is(err, store.ErrVersionConflict) {
        respondError(c, http.StatusConflict, "conflict", "modified concurrently; retry", nil)
        return
    }
    c.Error(err) // attach for logging middleware
    respondError(c, http.StatusInternalServerError, "internal_error", "internal error", nil)
}
```

Never leak a raw `err.Error()` or a DB string to the client; log it server-side, return a typed code. Full status-code
table in **`references/parsing-and-validation.md`**.

## OAuth 2.0 (resource server)

The service is an OAuth 2.0 **resource server**: it does not issue tokens, it **verifies** the bearer JWT on each
request against the authorization server's JWKS, and checks `exp`, `iss`, `aud`, and any required `scope`. Allow-list
the signing algorithms (never accept `none`), cache+rotate JWKS by `kid`, and gate enforcement behind a config flag so
local/dev and the test harness can run open:

```go
opts := []jwt.ParserOption{
    jwt.WithValidMethods([]string{"RS256", "ES256"}), // allow-list; reject "none"
    jwt.WithIssuer(cfg.Issuer),
    jwt.WithAudience(cfg.Audience),
    jwt.WithExpirationRequired(),
}
token, err := jwt.Parse(raw, keyfuncFromJWKS.Keyfunc, opts...)
```

Per-route scope checks, propagating claims via `context`, and the JWKS lifecycle are in **`references/auth-oauth2.md`**.

## Persistence

`pgx/v5` pool + `sqlc`-generated queries + `goose` migrations. Run command handlers in **one transaction** (write +
read-your-writes), enforce **optimistic concurrency** with a `UNIQUE` constraint, and translate `pgconn.PgError` code
`23505` into a typed conflict the HTTP layer maps to `409`. The transaction helper, the `defer Rollback` (no-op after
commit) idiom, and the sqlc config are in **`references/persistence.md`**.

## Streaming (SSE)

If the spec has an event stream: a single goroutine holds a dedicated `pgx.Conn` doing `LISTEN`, and fans `NOTIFY`'d
events out to per-connection buffered channels (drop-on-slow-consumer); each `GET /events` connection backfills
`WHERE id > Last-Event-ID` then goes live, de-duplicating on the sortable ULID cursor. See
**`references/streaming-sse.md`**.

## Testing & Contract Conformance

Three layers, all in **`references/testing-and-contract.md`**:

1. **Domain unit tests** — table-driven, one block per business rule, pure and fast (`go test`, no Docker).
2. **Functional tests** — `httptest.NewRecorder` against the real router with a throwaway Postgres via
   `testcontainers`. Boot a fresh DB per test; assert status + body shape.
3. **Contract tests** — serve the canonical OpenAPI at `/openapi.json`; a Go test asserts the router's routes equal the
   spec's operations (no missing, no extra); a schema fuzzer (e.g. Schemathesis) drives the live service against the
   spec.

## The Gate — every step must pass, in order

```bash
gofumpt -l .                 # formatting: must list no files
golangci-lint run            # v2; standard set + bodyclose, errorlint, gosec, revive, …
go vet ./...
go test -race ./...          # race detector on; covers success AND failure paths
```

Plus, when SQL or the spec changed: `go tool sqlc generate` (and fail CI on a diff) and the OpenAPI route-coverage test.
A step is done only when the whole gate exits zero.

## Quick Triage Table

| Situation                                            | Do this                                                                              |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Given an OpenAPI spec to implement                   | Embed + serve it verbatim; coverage-test routes; fuzz with Schemathesis              |
| Custom method `POST /x/{id}:action`                  | One `POST /x/:id` route → `splitCommand` on last colon → dispatch                    |
| `additionalProperties: false` in a schema            | `json.Decoder` + `DisallowUnknownFields`, not bare `ShouldBindJSON`                  |
| PATCH that must tell "field absent" from "set null"  | Tri-state type (`Set bool; Value *T`) with a custom `UnmarshalJSON`                  |
| Concurrent updates to one resource                   | Optimistic concurrency: `UNIQUE(stream,version)`; `23505` → `409`                    |
| Protect routes with OAuth 2.0                        | Resource-server JWT+JWKS middleware; allow-list algs; check `iss`/`aud`/`exp`/scope  |
| Need real DB in tests                                | `testcontainers-go/modules/postgres`, one container per test, `t.Cleanup`            |
| Wire/DB error must reach the client                  | Translate to a typed/sentinel error; `handleError` maps it; never leak raw strings   |
| Adding a dependency                                  | `go get …@latest && go mod tidy`; verify the resolved version + major in release notes|

## Common Mistakes (and the fix)

| Mistake                                                              | Fix                                                                            |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `gin.Default()` in production                                       | `gin.New()` + explicit `Recovery` (and your own logging) middleware           |
| Business logic in handlers (`pgx`/`gin` types in decision code)     | Pure `domain` package; handlers only bind, call, and map                      |
| Hand-maintaining OpenAPI via swag annotations                       | Serve the canonical spec; prove agreement with a route-coverage test          |
| `ShouldBindJSON` for a strict `additionalProperties:false` schema   | `DisallowUnknownFields` decoder; reject unknown keys with 422                  |
| `*string` for a PATCH field, losing "absent vs null"                | Tri-state `{Set bool; Value *T}` type                                         |
| Accepting any JWT alg (or `none`); skipping `aud`                   | `jwt.WithValidMethods([...])` allow-list; `WithIssuer`/`WithAudience`         |
| Returning `err.Error()` to the client                               | Map to a typed code + safe message; log the real error server-side            |
| `time.Now()` inside domain logic                                    | Inject a clock (`now time.Time` param / `App.Now`) for deterministic tests    |
| Pinning versions / committing a stale `go.sum`                      | `go get …@latest` + `go mod tidy`; track dev tools as `tool` directives       |
| Ignoring `Body.Close()` / leaking the LISTEN conn into the pool     | `bodyclose` lint; a standalone `pgx.Conn` for `LISTEN`, outside the pool      |
| Forgetting `-race`; testing against a mock DB only                  | `go test -race`; integration tests on a real Postgres via testcontainers      |

## Reference Files

Read the one you need; each is self-contained.

- **`references/project-structure.md`** — module layout, `tool` directives, `Makefile`, `golangci-lint` v2 + `gofumpt`
  config, multi-stage distroless `Dockerfile`, env-based `config`, server wiring, and graceful shutdown.
- **`references/routing-and-rpc.md`** — Gin engine, route groups, REST routes, the `{id}:command` colon dispatcher,
  405 handling, path/query param parsing, and the routing contract test.
- **`references/parsing-and-validation.md`** — DTOs, `DisallowUnknownFields`, `validator/v10` tags, tri-state optional
  fields, wire→domain conversion, the error envelope, and the status-code table.
- **`references/persistence.md`** — domain/store layering, `pgx`/`pgxpool`, `sqlc` config + queries, `goose`
  migrations, transactions, optimistic concurrency, and Postgres error translation.
- **`references/auth-oauth2.md`** — OAuth 2.0 resource-server middleware, JWT verification, JWKS lifecycle, algorithm
  allow-listing, `iss`/`aud`/`exp`/scope checks, and propagating claims.
- **`references/streaming-sse.md`** — SSE over `LISTEN/NOTIFY`, the fan-out hub, backfill/resume with `Last-Event-ID`,
  and slow-consumer handling.
- **`references/testing-and-contract.md`** — table-driven unit tests, `httptest` functional tests with
  `testcontainers`, the OpenAPI route-coverage test, and contract fuzzing.

## Pre-Commit Self-Check

Before saying "done" on a Go API change, verify:

- [ ] `gofumpt -l .` is empty and `golangci-lint run` passes; `go vet ./...` and `go test -race ./...` are green,
      covering success **and** failure paths.
- [ ] Decision logic lives in a pure `domain` package that imports only the stdlib; handlers only bind, call, and map.
- [ ] Every request body is decoded with unknown-field rejection where the schema demands it; every wire value is parsed
      into a typed domain value at the boundary.
- [ ] Every error returned to a client is a typed code + safe message in the one envelope; the raw error is logged, not
      leaked; `errors.Is`/`errors.As` (not string matching) drive the mapping.
- [ ] Custom methods route through a unit-tested `splitCommand`; a route-coverage test asserts the router equals the
      OpenAPI operations; a schema fuzzer runs against the live service.
- [ ] Protected routes verify the JWT signature against JWKS with an algorithm allow-list and check `iss`/`aud`/`exp`
      (+ scope); `none` is impossible; enforcement is config-gated.
- [ ] Command handlers run in one transaction; concurrency is guarded by a `UNIQUE` constraint mapped to `409`; the DB
      pool is sized explicitly and closed on shutdown.
- [ ] No version numbers were pinned by hand — deps were pulled with `@latest`, `go mod tidy` ran, and the resolved
      majors were verified; dev tools are `tool` directives.
- [ ] The server shuts down gracefully on `SIGINT`/`SIGTERM`; `context.Context` is the first parameter through the
      call chain; no package-level mutable globals.
