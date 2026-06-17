---
name: api-design-rust-axum
description: >-
    Use when building, scaffolding, or testing a REST or RPC HTTP API in Rust — implementing an OpenAPI/Swagger
    contract, standing up an Axum (or actix-web) service, or designing routes, extractors, and shared state. Covers
    resource-action RPC routes (`POST /tasks/{id}:complete`), serde request validation, the error-envelope /
    `IntoResponse` boundary, sqlx persistence with optimistic concurrency, OAuth 2.0 / OIDC bearer (JWT/JWKS) auth,
    Server-Sent Events, OpenAPI contract testing, and integration tests via `tower::oneshot` + `#[sqlx::test]`.
    Triggers on Axum, Tokio, or sqlx HTTP-API work — use it even when the user does not say "idiomatic". Pair it with
    `best-practices-rust` for line-level style.
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
- Server-Sent Events / live streaming (in-process `LISTEN/NOTIFY` for PoC, a GRIP proxy for production; mandatory
  30s keep-alive; `Last-Event-ID` resume)
- Emitting and contract-testing the OpenAPI document; integration tests via `tower::oneshot` + `#[sqlx::test]`;
  Schemathesis fuzzing
- Observability (structured tracing, open `/readyz`+`/livez` probes vs the gated `/healthz` report) and the
  production Dockerfile

Do not use it for: non-HTTP Rust (CLIs, embedded, libraries) — that is plain `best-practices-rust`; or for picking
business rules, which are the API's own and the one thing this skill deliberately leaves to you.

## Adopt, Don't Impose — These Are Greenfield Defaults

The stack and structure below are the blessed starting point for a **new** service. In an existing
codebase they yield to what the project already does — read the repo first and conform to it. Imposing
this skill's defaults on a working project is a failure mode, not thoroughness.

- **Persistence is a default, not a mandate.** If the project already has a datastore — SQLite, MySQL,
  MongoDB, a hosted API, anything — use it. Do **not** introduce Postgres alongside it. The persistence
  guidance here applies only when there is no datastore yet. The architecture (a pure core behind a store
  seam) holds regardless of engine; the engine choice is the project's, not the skill's.
- **Structure is a target, not a teardown.** The layering (pure domain core ← store ← HTTP edge) is the
  default for new work and a direction to refactor *toward*, but adapt it to the directory conventions the
  project already uses. Do not restructure a working codebase to match the diagrams here.
- **Run the project's toolchain, not your own.** Detect and use the project's existing package manager and
  task runner. Rust converges on `cargo`, but honor an existing `just`/`Makefile`, `cargo-make`, or
  container-based build and run tooling through it. If the project runs its tooling through `docker` /
  `docker compose` or a custom `Makefile`/script/task runner, invoke the tools that way instead of calling
  them directly. The named tools below are greenfield defaults — never a reason to migrate a project off
  what it already uses.

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
| SSE / realtime       | `axum::response::sse` (PoC); a GRIP proxy at scale         | In-process `LISTEN/NOTIFY` for PoC/<100 conns; front with Pushpin/Fastly Fanout for production. |

`[lints]`/profile/toolchain setup, feature-flag discipline, and the full `Cargo.toml` are in
`references/toolchain.md`.

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
    mod.rs          # router(state): routes, auth middleware, open probes (/readyz, /livez, /openapi.json)
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

The lib+bin rationale, the inward-dependency layering, `AppState`, and module visibility are detailed in
`references/project-structure.md`; the pure `decide`/`apply` core and injecting a `Clock` for deterministic time are
in `references/domain-core.md`. (Event sourcing — `decide`/`apply`/fold — is the worked example throughout, but the
same layering serves a plain CRUD service: the "domain" is then a service module and `store` writes rows directly.)

## Workflow: from an OpenAPI doc to a passing service

Build inward-out, gating each step (`fmt → clippy → test`, plus the offline `sqlx` check). This mirrors a PDCA
loop — finish and verify a layer before starting the next, so a contract misread surfaces once, cheaply.

1. **Read the contract into types.** Enumerate paths/operations, schemas, the error shape, and security schemes.
   Each schema → a strict DTO; the error object → your envelope; `additionalProperties:false` → `deny_unknown_fields`.
2. **Scaffold + toolchain.** Crate, `Cargo.toml` deps (current versions), `[lints]`, `rustfmt`, `rust-toolchain.toml`,
   an open `/readyz` (shallow DB ping) and bodyless `/livez`, the Dockerfile and compose. (`references/toolchain.md`,
   `references/bootstrap-and-config.md`, `references/observability-deployment.md`.)
3. **Migrations + schema**, then generate the offline `.sqlx` cache so CI builds need no live DB.
   (`references/persistence.md`.)
4. **Domain core, test-first.** Encode each invariant as a failing unit test, then the `decide`/`apply` to pass it.
   No I/O — this is where most of the logic and nearly all the tests live. (`references/domain-core.md`.)
5. **Persistence.** `load → fold`, and `commit` = append + project (+ notify) in **one transaction**; map the
   unique-violation to a typed conflict for optimistic concurrency. (`references/persistence.md`.)
6. **Confirm the API style** (REST / RPC / mixed / split — see *Decide the API Style First* in SKILL.md) before
   laying out routes; follow the contract if it encodes one, otherwise ask the user.
7. **HTTP edge.** Router, DTOs + parsing, REST handlers, then the RPC colon-dispatcher; wire `AppError: IntoResponse`.
   (`references/routing-and-rpc.md`, `references/validation.md`, `references/errors.md`.)
8. **Auth, SSE, OpenAPI** as the contract requires. (`references/auth-oauth2.md`, `references/sse.md`,
   `references/openapi-contract.md`.)
9. **Conformance.** `oneshot` tests per operation, a route-coverage contract test, then Schemathesis against the
   running container. (`references/testing.md`, `references/openapi-contract.md`.)

## Decide the API Style First — Confirm With the User

"REST with resource-action commands" is this skill's default, but it is not the only valid convention, and
the choice shapes every path. Before writing routes, confirm which style the API follows — if the OpenAPI
contract already encodes one, follow it; if you are greenfield or it is ambiguous, **ask the user rather
than assume**:

1. **Pure REST** — only resources and the uniform HTTP verbs; no action endpoints. State changes are
   modeled as resource mutations (`PATCH /users/{id}`).
2. **Pure RPC** — every operation is a named procedure (`POST /resetUserPassword`); resources are secondary
   or absent. (gRPC/Connect or JSON-RPC live here. If the user wants gRPC specifically, this skill's
   HTTP/REST machinery does not apply — say so.)
3. **Mixed: resources + actions on one tree** — REST resources plus resource-scoped commands as a sub-path.
   The colon form `POST /users/{id}:resetPassword` (Google AIP-136) is one spelling; a sub-resource path
   `POST /users/{id}/reset-password` is another. **This is the skill's default**, and the dispatcher below
   implements it.
4. **Split REST + RPC trees** — REST under one prefix and procedures under another, e.g. `/rest/users/{id}`
   and `/rpc/reset-user-password`.

Styles 2 and 4 reuse the same `parse → delegate → map` handler shape as the default; only the routing
layout changes. Pick one convention for the whole surface and keep it consistent.

## Version With Media Types or Headers — Never the URL Path

Do not put the version in the path (`/api/v1/users`, `/rest/v2/...`). URL-path versioning forks resource
identifiers, breaks caching and hypermedia links, and couples every client to a version string in every
URL. Prefer **media-type (content-negotiation) versioning** — `Accept: application/vnd.acme.user.v2+json`,
with the response echoing the chosen `Content-Type` — or, as a lighter option, a dedicated version header
(`Acme-Version: 2024-11-01`, date- or integer-based). Default to **not versioning at all** until a breaking
change forces it: evolve compatibly (add optional fields; never repurpose or remove existing ones) for as
long as you can, and version only the representations that actually break.

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
| Which routing convention to use           | Confirm REST / RPC / mixed / split with the user; default is mixed (resource + colon actions) |
| `POST /res/{id}:command` RPC              | Capture-and-dispatch: one `{id}` route, `rsplit_once(':')`, `match` command            |
| Turning any failure into an HTTP response | One `AppError` enum + `impl IntoResponse`; `From` for domain/store errors; `?`         |
| A SQL query                               | `sqlx::query!`/`query_as!` (compile-time checked) + committed `.sqlx` offline cache    |
| Two writes that must both land            | One `pool.begin()` transaction; commit at the end                                      |
| Concurrent-update safety                  | Optimistic: a unique `(stream, version)` → catch unique-violation → typed conflict→409 |
| Protecting routes                         | OIDC bearer middleware validating JWT vs JWKS; `/readyz` + `/livez` + `/openapi.json` open, `/healthz` gated; env toggle |
| Live updates to clients                   | SSE; in-process `LISTEN/NOTIFY` for PoC/<100 conns, a GRIP proxy (Pushpin/Fastly Fanout) for production; 30s keep-alive mandatory |
| Sortable id that is also a stream cursor  | `ULID` newtype (monotonic generator for event ids)                                     |
| Serving the OpenAPI doc                   | Embed & serve the canonical file; assert route coverage in a test (see ref)            |
| Testing a handler without a socket        | `app.oneshot(Request)` via `tower::ServiceExt`; `#[sqlx::test]` for a real DB          |
| Deterministic timestamps in tests         | Inject a `Clock` enum (`System` / `Fixed`) through `AppState`                          |

## Reference Files

Read the relevant file when the SKILL.md guidance leaves a judgment call open:

- `references/project-structure.md` — Lib+bin split, the inward-dependency layering, `AppState`, dependency
  injection, and module visibility.
- `references/toolchain.md` — The crate stack in depth, feature-flag choices, `Cargo.toml` + `[lints]` + release
  profile, `rust-toolchain.toml`, and the "verify current versions" workflow (`cargo add`/`update`/`audit`).
- `references/bootstrap-and-config.md` — The `main.rs` bootstrap wiring (tracing init, pool, migrate, serve), typed
  env `Config` that fails fast at boot, and graceful shutdown.
- `references/domain-core.md` — The pure `decide`/`apply` core vs a CRUD service module, newtype IDs, the injected
  `Clock`, `DomainError`, and the purity rules.
- `references/routing-and-rpc.md` — Axum router assembly, REST routing, extractors and their order, the
  `{id}:command` capture-and-dispatch pattern with tests, and middleware/layers.
- `references/validation.md` — Strict DTOs, `camelCase` + `deny_unknown_fields`, body parsing to 422, the
  `Option<Option<T>>` PATCH pattern, response envelopes via `From`, and date-vs-timestamp formatting.
- `references/errors.md` — The single `AppError: IntoResponse` boundary, the stable error envelope, `From`
  conversions from `DomainError`/`StoreError`, status-code mapping, and `WWW-Authenticate` on 401.
- `references/persistence.md` — `sqlx` pool, embedded migrations, compile-time-checked queries + offline cache,
  transactional `commit`, optimistic concurrency via unique-violation classification, and projection reads.
- `references/auth-oauth2.md` — OAuth 2.0 / OIDC resource-server validation: bearer extraction, `jsonwebtoken` +
  JWKS (by `kid`), `iss`/`aud`/`exp` checks, scope enforcement, the middleware gate, and the env toggle.
- `references/sse.md` — Server-Sent Events with `axum`: the in-process `tokio::broadcast` + Postgres
  `LISTEN/NOTIFY` PoC tier vs the production GRIP proxy (Pushpin/Fastly Fanout), backfill + `Last-Event-ID`
  resume, and the mandatory 30s keep-alive.
- `references/openapi-contract.md` — Serve-canonical vs `utoipa`-derive, the emitted-≡-canonical / route-coverage
  contract test, and schema-shape proxy assertions.
- `references/testing.md` — The test pyramid: pure-core unit tests, `tower::oneshot` functional tests,
  `#[sqlx::test]` isolated databases, the contract test, and Schemathesis fuzzing; plus the mechanical gate.
- `references/observability-deployment.md` — `tracing` JSON logs, the two probes (open shallow `/readyz` +
  `/livez` vs gated detailed `/healthz`), the multi-stage distroless Dockerfile, and `compose.yaml`.

## Common Mistakes (and the fix)

| Mistake                                                                  | Fix                                                                            |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| Business logic inside `async` handlers, tangled with `axum`/`sqlx`       | Pure `decide`/service core; handler = parse → delegate → map; test the core    |
| `Json<T>` extractor for requests, getting Axum's plain-text 422          | Take `Bytes`, parse yourself, map errors to the contract's envelope            |
| DTOs without `deny_unknown_fields`                                       | Add it — that _is_ `additionalProperties:false`; unknown fields → 422          |
| Conflating "field absent" with "field set to null" in PATCH              | `Option<Option<T>>` + a `double_option` deserializer                           |
| Per-handler `(StatusCode, Json)` tuples; status logic scattered          | One `AppError: IntoResponse`; every handler returns `Result<_, AppError>`      |
| Routing `/{id}:command` as a literal and fighting the path capture       | Capture the whole segment, `rsplit_once(':')`, dispatch; test the split        |
| Version in the URL path (`/api/v1/...`)                                  | Version via media type (`Accept: application/vnd...+json`) or a version header; never the path |
| Runtime-built SQL strings / unchecked queries                            | `query!`/`query_as!` checked against the DB; commit the `.sqlx` offline cache  |
| Append and projection in separate transactions                           | One `tx`: append → project (→ notify) → commit; read-your-writes holds         |
| `SELECT … version` then `UPDATE` to guard concurrency                    | Optimistic: unique `(stream, version)`; catch the unique-violation → 409       |
| Fetching JWKS over HTTP on every request (or baking keys into the build) | Cache decoding keys by `kid`; refresh out of band; config-provided in tests    |
| One SSE query at connect, missing events past the page / on reconnect    | Page the backfill to the live edge, then dedupe the live stream by id cursor   |
| Fanning out SSE from the app at scale                                    | Front it with a GRIP proxy (Pushpin/Fastly Fanout); the app publishes, the proxy holds connections |
| Optional/absent SSE keep-alive                                           | Mandatory heartbeat every 30s                                                  |
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
- [ ] Auth (when required) validates signature + `exp`/`iss`/`aud` against JWKS by `kid`; `/readyz` + `/livez` +
      `/openapi.json` stay open while `/healthz` is gated; the gate is env-toggled and off by default for the test harness.
- [ ] The served OpenAPI matches the canonical contract, asserted by a test; integration tests use `oneshot` +
      `#[sqlx::test]`; the running container passes Schemathesis.
- [ ] Logs are structured (`tracing` JSON) and never log secrets/tokens; the open `/readyz` does a shallow DB ping
      (200/503), `/livez` returns a bodyless 200, and the detailed `/healthz` is gated; the binary
      `#![forbid(unsafe_code)]` and reads config from env, failing fast.
- [ ] SSE streams emit a keep-alive heartbeat at least every 30s; at scale the app publishes to a GRIP proxy
      (Pushpin/Fastly Fanout) rather than fanning out connections itself.
- [ ] All dependency versions were resolved against the **current** crates.io releases, not copied from this skill.
