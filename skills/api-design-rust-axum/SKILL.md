---
name: api-design-rust-axum
description: >-
    Use when building, scaffolding, structuring, or testing a REST or RPC HTTP API/service/backend in Rust — including
    implementing an OpenAPI/Swagger contract in Rust, standing up an Axum (or actix-web/axum-tower) service, designing
    routes/handlers/extractors, resource-action RPC routes like `POST /tasks/{id}:complete`, request parsing and
    validation with serde, the error-envelope/`IntoResponse` boundary, sqlx persistence and migrations, OAuth 2.0 /
    OIDC bearer-token (JWT/JWKS) auth, Server-Sent Events / streaming, emitting and contract-testing the OpenAPI doc,
    `#[tokio::test]` + `tower::oneshot` + `#[sqlx::test]` integration tests, Schemathesis fuzzing, tracing/health
    probes, and the multi-stage Dockerfile. Targets Rust 1.96 / edition 2024, Axum 0.8+, Tokio 1.x, sqlx 0.8+. Covers
    the cross-cutting skeleton so only the API's own business logic is left to write. Use this even when the user does
    not say "idiomatic" — pair it with best-practices-rust for line-level Rust style.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# Building REST & RPC APIs in Rust

This skill is the **skeleton for a production HTTP API in Rust**: how to lay out the crate, which crates to pull in,
how to route (including resource-action RPC), parse and validate requests, map errors to a stable wire envelope,
persist with `sqlx`, gate with OAuth 2.0 / OIDC, stream with SSE, and prove conformance against an OpenAPI contract.
Given an OpenAPI description, follow this and the only thing left to write is the API's own business logic.

> **This skill governs the _shape of the service_; `best-practices-rust` governs the _shape of the code_.** They are
> complementary — load both for any API task. Where they overlap (error types, borrowing, `match` exhaustiveness),
> `best-practices-rust` is the authority; this skill never restates line-level idioms, only the service architecture
> that uses them.

> **Verify crate versions yourself — this skill pins none.** Rust's web stack moves fast (Axum/Tokio/Tower
> co-evolve; `sqlx` 0.9 and `jsonwebtoken` 10 shipped after the examples here were written). The crate names and
> roles below are stable advice; the version numbers are **not**. Before adding or bumping a dependency, check
> crates.io / docs.rs / the changelog for the **current** stable release and its API, run `cargo add <crate>` (which
> writes the latest compatible req), and `cargo update` deliberately. Treat every version string in this skill and
> its references as illustrative, not a recommendation to freeze. Rust 1.96 / edition 2024 is the deliberate
> _language_ floor, not a tool version.

## The One Idea

**Push every decision to the layer that can prove it, and keep the HTTP edge thin.** An API in Rust earns its keep
when the type system, not the handler, enforces the contract: a `decide`/service function that is pure and total
(an exhaustive `match` on commands), DTOs whose `#[serde(deny_unknown_fields)]` _is_ the `additionalProperties:false`
clause, a single `AppError: IntoResponse` that is the only place a status code is chosen, and `sqlx` queries verified
against the real schema at compile time. The handler then reads top-to-bottom as _parse → delegate → map_, with `?`
carrying every failure to the one boundary that renders it. When that structure is in place, business logic is the
only thing you actually hand-write, and the compiler — not a code review — catches the contract drift.

Two consequences shape everything below:

1. **The wire contract is data, not prose.** Mirror the OpenAPI schema in strict serde structs and one error
   envelope; let serde and the type checker reject anything off-contract before a handler runs.
2. **Layers depend inward.** `http` knows `domain` and `store`; `domain` knows neither. The pure core has no `async`,
   no `axum`, no `sqlx` — which is exactly why it is trivially unit-testable and why the invariants live there.

## When to Use This Skill

- Implementing an OpenAPI/Swagger contract in Rust, or scaffolding a new Rust HTTP service from scratch
- Adding or restructuring routes, handlers, extractors, middleware, or shared state in Axum (or actix-web)
- Routing resource-action RPC endpoints (`POST /resource/{id}:action`) alongside REST
- Request parsing/validation, response envelopes, and the error → HTTP-status boundary
- Wiring `sqlx` (pool, migrations, compile-time-checked queries, transactions, optimistic concurrency)
- OAuth 2.0 / OIDC resource-server auth: bearer-token extraction, JWT/JWKS validation, scope checks, an auth toggle
- Server-Sent Events / live streaming (incl. Postgres `LISTEN/NOTIFY` fan-out and `Last-Event-ID` resume)
- Emitting and contract-testing the OpenAPI document; integration tests via `tower::oneshot` + `#[sqlx::test]`;
  Schemathesis fuzzing
- Observability (structured tracing, `/healthz`/`/readyz`) and the production Dockerfile

Do not use it for: non-HTTP Rust (CLIs, embedded, libraries) — that is plain `best-practices-rust`; or for picking
business rules, which are the API's own and the one thing this skill deliberately leaves to you.

## The Dependency Stack

Names and roles are the durable advice; **resolve current versions with `cargo add`**. A typical REST/RPC service:

| Concern              | Crate(s)                                                   | Notes                                                                             |
| -------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------- |
| HTTP framework       | `axum` (+ `tower`, `tower-http`)                           | Tower middleware ecosystem; `tower-http` for trace/CORS/compression/timeout.      |
| Async runtime        | `tokio` (`features = ["full"]` in the binary)              | One runtime, chosen by the binary — keep it out of the pure core.                 |
| Database             | `sqlx` (`postgres`, `macros`, `migrate`, `chrono`, `json`) | Compile-time-checked `query!`/`query_as!`; offline `.sqlx` cache for CI.          |
| Serialization        | `serde` + `serde_json`                                     | Strict DTOs: `rename_all = "camelCase"`, `deny_unknown_fields`.                   |
| Errors               | `thiserror` (domain/store enums) → one app `IntoResponse`  | `anyhow` only for the binary's bootstrap, never on the request path.              |
| Auth (resource srv.) | `jsonwebtoken` + a JWKS source                             | Validate signature + `exp`/`iss`/`aud`; cache keys by `kid`.                      |
| IDs                  | `ulid` (or `uuid`) wrapped in newtypes                     | Sortable ids that double as the event/stream cursor; newtypes prevent id mixups.  |
| Time                 | `chrono` (`features = ["serde"]`)                          | RFC3339 timestamps vs `NaiveDate` date-only — keep the two distinct in the types. |
| Tracing              | `tracing` + `tracing-subscriber` (`json`, `env-filter`)    | Structured stdout logs; level via `RUST_LOG`.                                     |
| Validation           | field checks in the core, or `garde`/`validator`           | Prefer the decider; reach for a crate only for large declarative rule sets.       |
| OpenAPI              | serve the canonical doc, or derive with `utoipa`           | See `references/openapi-contract.md` for the trade-off.                           |
| Test (HTTP)          | `tower` (`util`) + `http-body-util` (dev-deps)             | `ServiceExt::oneshot` drives the router in-process — no live port.                |

`[lints]`/profile/toolchain setup, feature-flag discipline, and the full `Cargo.toml` are in
`references/dependencies.md`.

## The Project Skeleton

A library crate (everything testable) plus a thin `main.rs` binary. Modules depend **inward**:
`http → {domain, store}`, and `domain` depends on neither.

```
src/
  lib.rs            # pub mod wiring; re-export router + AppState
  main.rs           # #![forbid(unsafe_code)]; tracing, pool, migrate, serve — bootstrap only
  config.rs         # env → typed Config (fail fast at boot)
  ids.rs            # newtype IDs (TaskId, …) — sortable, prefix-tagged, serde as bare string
  domain/           # PURE: no async, no axum, no sqlx
    mod.rs
    {aggregate}.rs  # state + commands + events; decide(state, cmd) -> Result<Events, DomainError>; apply(state, ev)
    error.rs        # DomainError (thiserror)
  store/            # sqlx: pool, migrations, transactional writes, projection reads
    mod.rs          # load → fold → commit (append + project + notify, one tx)
    reads.rs        # query_as! read models behind list/detail/view endpoints
    error.rs        # StoreError (thiserror): map unique-violation → typed conflict
  http/             # the Axum edge — thin handlers
    mod.rs          # router(state): routes, auth middleware, meta endpoints
    state.rs        # AppState { store, clock, auth, … } — cheap to clone
    error.rs        # AppError: IntoResponse → the wire error envelope (the ONLY status map)
    dto.rs          # request/response structs (camelCase, deny_unknown_fields) + parsing
    {resource}.rs   # REST handlers
    commands.rs     # RPC `{id}:command` capture-and-dispatch
    sse.rs          # streaming endpoint
  auth.rs           # OIDC bearer gate (off by default)
tests/              # integration: oneshot against the router, #[sqlx::test] DB, contract coverage
migrations/         # sqlx migrate
```

The pure-core / store / edge split, the lib+bin rationale, `AppState`, and injecting a `Clock` for deterministic
time are detailed in `references/project-structure.md`. (Event sourcing — `decide`/`apply`/fold — is the worked
example throughout, but the same layering serves a plain CRUD service: the "domain" is then a service module and
`store` writes rows directly.)

## Workflow: from an OpenAPI doc to a passing service

Build inward-out, gating each step (`fmt → clippy → test`, plus the offline `sqlx` check). This mirrors a PDCA
loop — finish and verify a layer before starting the next, so a contract misread surfaces once, cheaply.

1. **Read the contract into types.** Enumerate paths/operations, schemas, the error shape, and security schemes.
   Each schema → a strict DTO; the error object → your envelope; `additionalProperties:false` → `deny_unknown_fields`.
2. **Scaffold + toolchain.** Crate, `Cargo.toml` deps (current versions), `[lints]`, `rustfmt`, `rust-toolchain.toml`,
   a `/healthz` that returns 200, the Dockerfile and compose. (`references/dependencies.md`,
   `references/observability-deployment.md`.)
3. **Migrations + schema**, then generate the offline `.sqlx` cache so CI builds need no live DB.
   (`references/persistence.md`.)
4. **Domain core, test-first.** Encode each invariant as a failing unit test, then the `decide`/`apply` to pass it.
   No I/O — this is where most of the logic and nearly all the tests live. (`references/project-structure.md`.)
5. **Persistence.** `load → fold`, and `commit` = append + project (+ notify) in **one transaction**; map the
   unique-violation to a typed conflict for optimistic concurrency. (`references/persistence.md`.)
6. **HTTP edge.** Router, DTOs + parsing, REST handlers, then the RPC colon-dispatcher; wire `AppError: IntoResponse`.
   (`references/routing-and-rpc.md`, `references/request-and-response.md`, `references/error-handling.md`.)
7. **Auth, SSE, OpenAPI** as the contract requires. (`references/auth-oauth2.md`, `references/sse-streaming.md`,
   `references/openapi-contract.md`.)
8. **Conformance.** `oneshot` tests per operation, a route-coverage contract test, then Schemathesis against the
   running container. (`references/testing.md`, `references/openapi-contract.md`.)

## Resource-action RPC routing (the one Axum gotcha)

Commands like `POST /tasks/{taskId}:complete` collide with `matchit`'s path capture: a literal `:` after a `{param}`
is fragile. **Default to capture-and-dispatch** — register `POST /tasks/{taskId}` so the whole segment (colon suffix
included) is captured, then `rsplit_once(':')` into `(id, command)` and `match` the command, 404-ing unknown
commands and no-colon paths. One handler, robust across router versions, and the REST `GET/PATCH /tasks/{taskId}`
share the route. Always unit-test that `task_…:complete` splits correctly and a plain id is **not** mis-split. Full
treatment in `references/routing-and-rpc.md`.

## Quick Triage Table

| Situation                                 | Default choice                                                                         |
| ----------------------------------------- | -------------------------------------------------------------------------------------- |
| Framework choice                          | `axum` + `tower-http`, unless the project already standardizes on `actix-web`          |
| Reading a JSON request body               | Take `Bytes`, `serde_json::from_slice` → a `deny_unknown_fields` DTO → 422 on failure  |
| `additionalProperties: false`             | `#[serde(deny_unknown_fields)]` on the request DTO                                     |
| PATCH "absent vs explicit null vs value"  | `Option<Option<T>>` with a `double_option` deserializer + `#[serde(default)]`          |
| `POST /res/{id}:command` RPC              | Capture-and-dispatch: one `{id}` route, `rsplit_once(':')`, `match` command            |
| Turning any failure into an HTTP response | One `AppError` enum + `impl IntoResponse`; `From` for domain/store errors; `?`         |
| A SQL query                               | `sqlx::query!`/`query_as!` (compile-time checked) + committed `.sqlx` offline cache    |
| Two writes that must both land            | One `pool.begin()` transaction; commit at the end                                      |
| Concurrent-update safety                  | Optimistic: a unique `(stream, version)` → catch unique-violation → typed conflict→409 |
| Protecting routes                         | OIDC bearer middleware validating JWT vs JWKS; meta routes always open; env toggle     |
| Live updates to clients                   | SSE (`axum::response::sse`) fed by a `tokio::broadcast`; Postgres `LISTEN/NOTIFY`      |
| Sortable id that is also a stream cursor  | `ULID` newtype (monotonic generator for event ids)                                     |
| Serving the OpenAPI doc                   | Embed & serve the canonical file; assert route coverage in a test (see ref)            |
| Testing a handler without a socket        | `app.oneshot(Request)` via `tower::ServiceExt`; `#[sqlx::test]` for a real DB          |
| Deterministic timestamps in tests         | Inject a `Clock` enum (`System` / `Fixed`) through `AppState`                          |

## Reference Files

Read the relevant file when the SKILL.md guidance leaves a judgment call open:

- `references/dependencies.md` — The crate stack in depth, feature-flag choices, `Cargo.toml` + `[lints]` + release
  profile, `rust-toolchain.toml`, and the "verify current versions" workflow (`cargo add`/`update`/`audit`).
- `references/project-structure.md` — Lib+bin split, the inward-dependency layering, the pure `decide`/`apply` core
  vs a CRUD service module, `AppState`, dependency injection, and the injected `Clock`.
- `references/routing-and-rpc.md` — Axum router assembly, REST routing, extractors and their order, the
  `{id}:command` capture-and-dispatch pattern with tests, middleware/layers, and graceful shutdown.
- `references/request-and-response.md` — Strict DTOs, `camelCase` + `deny_unknown_fields`, body parsing to 422, the
  `Option<Option<T>>` PATCH pattern, response envelopes via `From`, and date-vs-timestamp formatting.
- `references/error-handling.md` — The single `AppError: IntoResponse` boundary, the stable error envelope, `From`
  conversions from `DomainError`/`StoreError`, status-code mapping, and `WWW-Authenticate` on 401.
- `references/persistence.md` — `sqlx` pool, embedded migrations, compile-time-checked queries + offline cache,
  transactional `commit`, optimistic concurrency via unique-violation classification, and projection reads.
- `references/auth-oauth2.md` — OAuth 2.0 / OIDC resource-server validation: bearer extraction, `jsonwebtoken` +
  JWKS (by `kid`), `iss`/`aud`/`exp` checks, scope enforcement, the middleware gate, and the env toggle.
- `references/sse-streaming.md` — Server-Sent Events with `axum`, a `tokio::broadcast` fan-out, Postgres
  `LISTEN/NOTIFY` via `PgListener`, backfill + `Last-Event-ID` resume, and keep-alive.
- `references/openapi-contract.md` — Serve-canonical vs `utoipa`-derive, the emitted-≡-canonical / route-coverage
  contract test, and schema-shape proxy assertions.
- `references/testing.md` — The test pyramid: pure-core unit tests, `tower::oneshot` functional tests,
  `#[sqlx::test]` isolated databases, the contract test, and Schemathesis fuzzing; plus the mechanical gate.
- `references/observability-deployment.md` — `tracing` JSON logs, `/healthz` vs `/readyz`, typed env config that
  fails fast, the multi-stage distroless Dockerfile, and `compose.yaml`.

## Common Mistakes (and the fix)

| Mistake                                                                  | Fix                                                                            |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| Business logic inside `async` handlers, tangled with `axum`/`sqlx`       | Pure `decide`/service core; handler = parse → delegate → map; test the core    |
| `Json<T>` extractor for requests, getting Axum's plain-text 422          | Take `Bytes`, parse yourself, map errors to the contract's envelope            |
| DTOs without `deny_unknown_fields`                                       | Add it — that _is_ `additionalProperties:false`; unknown fields → 422          |
| Conflating "field absent" with "field set to null" in PATCH              | `Option<Option<T>>` + a `double_option` deserializer                           |
| Per-handler `(StatusCode, Json)` tuples; status logic scattered          | One `AppError: IntoResponse`; every handler returns `Result<_, AppError>`      |
| Routing `/{id}:command` as a literal and fighting the path capture       | Capture the whole segment, `rsplit_once(':')`, dispatch; test the split        |
| Runtime-built SQL strings / unchecked queries                            | `query!`/`query_as!` checked against the DB; commit the `.sqlx` offline cache  |
| Append and projection in separate transactions                           | One `tx`: append → project (→ notify) → commit; read-your-writes holds         |
| `SELECT … version` then `UPDATE` to guard concurrency                    | Optimistic: unique `(stream, version)`; catch the unique-violation → 409       |
| Fetching JWKS over HTTP on every request (or baking keys into the build) | Cache decoding keys by `kid`; refresh out of band; config-provided in tests    |
| One SSE query at connect, missing events past the page / on reconnect    | Page the backfill to the live edge, then dedupe the live stream by id cursor   |
| `utoipa` doc silently drifting from the canonical OpenAPI                | Serve the canonical doc and assert route coverage, or test emitted ≡ canonical |
| `Utc::now()` straight in handlers, making tests time-dependent           | Inject a `Clock` (`System`/`Fixed`) via `AppState`                             |
| Spawning a server + real socket in tests                                 | `router.oneshot(request)` in-process; `#[sqlx::test]` for an isolated DB       |
| Pinning crate versions from memory / this skill                          | `cargo add` the current release; verify the API on docs.rs; `cargo update`     |

## Pre-Flight Self-Check

Before calling an API change done, verify:

- [ ] `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and
      `cargo test` (+ `cargo test --doc`) are all green; `cargo sqlx prepare --check` confirms the offline cache.
- [ ] Every request DTO is `#[serde(deny_unknown_fields)]` + `camelCase`; PATCH bodies model absent/null/value
      correctly; body-parse failures return the contract's 422 envelope, not Axum's default.
- [ ] There is exactly **one** place that maps an error to an HTTP status (`AppError: IntoResponse`); handlers
      return `Result<_, AppError>` and propagate with `?`; 401s carry `WWW-Authenticate`.
- [ ] The business core is pure (no `axum`/`sqlx`/`async`) and has a unit test per invariant; handlers are thin.
- [ ] SQL uses compile-time-checked `sqlx` macros; multi-statement writes share one transaction; concurrency is
      guarded optimistically (unique violation → typed conflict → 409).
- [ ] RPC `{id}:command` routes use capture-and-dispatch with a unit test for the split; unknown commands → 404.
- [ ] Auth (when required) validates signature + `exp`/`iss`/`aud` against JWKS by `kid`; meta routes stay open;
      the gate is env-toggled and off by default for the test harness.
- [ ] The served OpenAPI matches the canonical contract, asserted by a test; integration tests use `oneshot` +
      `#[sqlx::test]`; the running container passes Schemathesis.
- [ ] Logs are structured (`tracing` JSON) and never log secrets/tokens; `/healthz` and `/readyz` behave per spec;
      the binary `#![forbid(unsafe_code)]` and reads config from env, failing fast.
- [ ] All dependency versions were resolved against the **current** crates.io releases, not copied from this skill.
