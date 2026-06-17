---
name: api-design-python-fastapi
description: >-
    Use when building, structuring, or testing a REST or RPC API in Python with FastAPI — scaffolding a service,
    implementing an OpenAPI/Swagger contract, or organizing routers, Pydantic models, and dependencies. Covers async
    SQLAlchemy + asyncpg persistence with optimistic concurrency, resource-action RPC routes
    (`POST /things/{id}:action`), boundary validation and a single error envelope (incl. FastAPI's 422 reconciliation),
    OAuth 2.0 / OIDC JWT auth, server-sent events, and the emitted-OpenAPI ≡ canonical contract test (httpx
    ASGITransport, Schemathesis). Triggers on FastAPI, uvicorn, Pydantic v2, `Depends()`/`Annotated` injection, or just
    an OpenAPI doc plus "a Python API" — even when the user does not say FastAPI. Layer it on `best-practices-python`
    for language-level style.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# Build REST / RPC APIs with FastAPI

This skill is a **build playbook**: given an OpenAPI/RPC contract, it gives you the skeleton of a well-structured,
fully-typed, thoroughly-tested FastAPI service — project layout, dependencies, routing (including resource-action RPC),
boundary validation, an error model, async persistence, OAuth 2.0, SSE, and contract testing — so the only thing left
to write is the business logic unique to your API.

> **Do not pin versions from this document.** FastAPI, Pydantic, SQLAlchemy, uvicorn, uv, Ruff, the type checker,
> pytest, and Schemathesis all release frequently. This skill names libraries, never version numbers. When you add a
> dependency, run `uv add <pkg>` and let the resolver pull the **current** release; verify on PyPI rather than trusting
> a number you remember. The architecture below holds across recent releases. Targets: Python 3.13+ (use 3.14 idioms
> where the project allows), FastAPI's current line, Pydantic **v2**, SQLAlchemy **2.0** async.

## The One Idea

**The contract is the source of truth; FastAPI is the adapter.** Keep all business logic in a pure, fully-typed
**domain core** that knows nothing about HTTP, and let FastAPI + Pydantic own the **edge** — parsing, validation,
serialization, dependency injection, and OpenAPI emission. Two payoffs fall out of that separation:

1. **The contract is testable from both sides.** The app _emits_ an OpenAPI doc that a test asserts is identical to the
   canonical spec, and a property-based fuzzer (Schemathesis) _drives_ the running app against that same spec. Pass
   both → contract-correct.
2. **The domain is testable without a server.** `decide(state, command) -> events` is a pure function; its entire
   behaviour is covered by fast unit tests before a single route exists. HTTP becomes a thin, boring translation layer.

Everything below serves that split: dependencies point **inward** (`api → store → domain`, never the reverse), and the
HTTP layer does nothing but translate bytes ↔ domain calls.

## Relationship to `best-practices-python`

This skill **layers on top of `best-practices-python`** the way `best-practices-react` builds on
`best-practices-typescript`. That skill governs language style — type hints everywhere, frozen dataclasses as value
objects, the enum family, `Protocol` interfaces, EAFP, modern syntax (`list[int]`, `X | None`, PEP 695 generics),
the uv + Ruff + type-checker toolchain. **Read it for any `.py` you write.** This skill covers only what FastAPI leaves
open: structure, routing, the validation/serialization boundary, persistence, auth, SSE, and contract testing.

Where they meet, **framework idiom wins** — exactly as `best-practices-python` itself instructs. At the HTTP edge you
model bodies as **Pydantic** models (not frozen dataclasses), wire collaborators through **`Depends(...)`** (not
hand-rolled Protocols), and let Pydantic validate at the boundary. Inside the domain core, revert to the plain-Python
defaults: frozen dataclasses, `StrEnum`, pure functions, injected Protocols.

## When to use this skill

- Scaffolding a new FastAPI service, or adding a feature/endpoint to one
- Turning an OpenAPI/Swagger document into a running, tested Python API
- Designing routers, Pydantic request/response models, and dependency wiring
- Implementing resource-action **RPC** routes (`POST /tasks/{id}:complete`) alongside REST
- Wiring async SQLAlchemy 2.0 + asyncpg, Alembic migrations, transactional writes, optimistic concurrency
- Adding OAuth 2.0 / OIDC resource-server JWT validation, or server-sent events
- Writing the test pyramid and the **emitted-OpenAPI ≡ canonical-spec** contract test

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
  task runner. If the project uses `uv`, run every tool through it (`uv run ruff`, `uv run pytest`) rather
  than invoking tools directly; if it uses Poetry, pip-tools, pipenv, or conda, use that. `uv` is the
  greenfield default, not a migration mandate. If the project runs its tooling through `docker` /
  `docker compose` or a custom `Makefile`/script/task runner, invoke the tools that way instead of calling
  them directly. The named tools below are greenfield defaults — never a reason to migrate a project off
  what it already uses.

## The dependency stack (add with `uv`, verify latest, never hand-pin)

Add these with `uv add` / `uv add --dev`; the lockfile records exact versions. Reach for a library only when the
feature needs it — don't install auth or SSE deps for a service that has neither.

| Concern                | Library                                     | Notes                                                         |
| ---------------------- | ------------------------------------------- | ------------------------------------------------------------- |
| Package/venv manager   | **uv**                                      | Greenfield default. In a `uv` project every command is `uv run …`; in a Poetry/pip-tools/pipenv/conda project, use that project's runner. |
| Web framework          | **fastapi**                                 | Emits OpenAPI **3.1** natively.                               |
| ASGI server            | **uvicorn[standard]**                       | `uvicorn`/`uvloop`/`httptools`; add Granian only if measured. |
| Validation / models    | **pydantic** (v2)                           | `ConfigDict(extra="forbid")` → `additionalProperties:false`.  |
| Settings               | **pydantic-settings**                       | Env-sourced `Settings`; typed, validated, no `os.environ`.    |
| DB toolkit             | **sqlalchemy[asyncio]** (2.0)               | Core `text()` is enough for an event store; ORM is optional.  |
| Async driver           | **asyncpg**                                 | Postgres; also exposes `LISTEN/NOTIFY` for SSE.               |
| Migrations             | **alembic**                                 | Async env; run out of band, never per worker.                 |
| Server-sent events     | **sse-starlette**                           | `EventSourceResponse(ping=30)`; pair with asyncpg `add_listener` for PoC, a GRIP proxy (Pushpin/Fastly Fanout) at scale. |
| Auth (resource server) | **pyjwt[crypto]**                           | `PyJWKClient` validates RS256/ES256 against the issuer JWKS.  |
| IDs                    | **python-ulid**                             | Sortable, prefixed string ids (`task_01J…`).                  |
| Logging                | **structlog** (or stdlib `logging` + JSON)  | Structured, to stdout. Do **not** unit-test logging.          |
| Tests                  | **pytest**, **pytest-asyncio**, **httpx**   | `httpx.ASGITransport` drives the app in-process, no socket.   |
| Contract fuzzing       | **schemathesis**                            | Property-based testing generated from the OpenAPI schema.     |
| Lint + format          | **ruff**                                    | `ruff check` + `ruff format`.                                 |
| Types                  | **mypy** (`--strict`) or **pyright**/**ty** | Strict mode is the gate — it is your real correctness signal. |

## Project layout (`src/` layout, one `pyproject.toml`)

Organize by **layer**, with dependencies pointing inward. The domain core has no FastAPI, SQLAlchemy, or Pydantic
import; the store has no FastAPI import; only `api/` imports FastAPI.

```
service/
  pyproject.toml  uv.lock  alembic.ini  Dockerfile  compose.yaml  Makefile
  migrations/                      # Alembic async env + versioned DDL
  src/<pkg>/
    __init__.py
    main.py            # create_app() factory + lifespan; __main__ runs uvicorn
    config.py          # pydantic-settings Settings
    db.py              # async engine + session factory
    domain/            # PURE: no I/O. decide()/apply(), value objects, enums, errors
    store/             # persistence: transactional append/upsert, queries, codec
    api/
      deps.py          # Depends() providers + Annotated aliases
      schemas.py       # Pydantic request/response models (extra="forbid")
      errors.py        # exception handlers → the error envelope
      <resource>.py    # one router module per resource
      commands.py      # the RPC colon-routes
  tests/
    unit/              # pure domain — fast, no DB, no HTTP
    integration/       # store + a real database
    functional/        # HTTP black-box via httpx ASGITransport
    contract/          # app.openapi() ≡ canonical spec; route coverage
```

See `references/bootstrap-and-config.md` for the app factory, `lifespan`, settings, and dependency injection in full.

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

## Core defaults — apply unless the contract gives a reason not to

1. **Contract-first.** Treat the OpenAPI doc as frozen. If it looks wrong, raise it — don't quietly diverge. Decide
   early whether the app **emits** its schema (FastAPI generates it from your routes/models) or **serves a canonical
   file verbatim**; a test pins emitted ≡ canonical either way. See `references/openapi-contract.md`.
2. **Three layers, dependencies inward.** `domain/` (pure, all the rules) ← `store/` (persistence) ← `api/` (HTTP).
   The domain core imports nothing framework-shaped and is unit-tested in isolation.
3. **App factory + `lifespan`.** Build the app in `create_app(...)` that accepts injected collaborators (store, clock,
   settings) so tests substitute fakes. Manage startup/shutdown with an `@asynccontextmanager` `lifespan`, never the
   deprecated `@app.on_event`.
4. **Typed settings via `pydantic-settings`.** One `Settings(BaseSettings)`; read config there, never `os.environ`
   scattered through the code.
5. **Inject with `Depends()` + `Annotated`.** Define `Store = Annotated[EventStore, Depends(get_store)]` once and reuse;
   never construct engines, clients, or stores inside a handler.
6. **Pydantic at the boundary, `extra="forbid"`.** Every request body is a Pydantic model with
   `model_config = ConfigDict(extra="forbid")`; map camelCase wire fields with `alias` + `populate_by_name`. Convert to
   a domain command (`to_command()`) at the edge — don't pass Pydantic models into the domain.
7. **REST + the RPC colon pattern.** Resource-action commands use a literal colon: `POST /tasks/{task_id}:complete`.
   Constrain the path param to exclude the colon — `Annotated[str, Path(pattern=r"^[^:/]+$")]` — and register specific
   command routes before the generic `/tasks/{task_id}`. See `references/routing-and-rpc.md`.
8. **One error envelope; map every failure to it.** Define a domain exception hierarchy, register
   `@app.exception_handler(...)` for each, and **reconcile FastAPI's default 422**: install a `RequestValidationError`
   handler so the _body_ matches your envelope (status stays 422). See `references/errors.md`.
9. **Async all the way down.** `async def` handlers, async engine, async sessions. Never call blocking I/O on the event
   loop; if a dependency is sync (e.g. a JWKS fetch), make the _dependency_ a plain `def` so FastAPI runs it in the
   threadpool.
10. **Transactional writes + optimistic concurrency.** Append/insert and update projections in **one** transaction; let
    a `UNIQUE(stream, version)` collision surface as a 409 conflict. See `references/persistence.md`.
11. **SSE: in-process `LISTEN/NOTIFY` is the PoC tier; a GRIP proxy is production.** When you stream, a single shared
    listener fans events to per-subscriber `asyncio.Queue`s through `EventSourceResponse`; `Last-Event-ID` backfills
    then goes live. That in-process fan-out holds for a PoC or low-concurrency tool (**under ~100 concurrent streams on
    one instance**); for production or anything user-facing at scale, front it with a GRIP proxy (**Pushpin** or
    **Fastly Fanout**) — the app *publishes*, the proxy holds connections. A **30-second keep-alive is mandatory** either
    way (`EventSourceResponse(..., ping=30)`). See `references/sse.md`.
12. **OAuth 2.0 as a gated dependency.** Validate the bearer JWT against the issuer's JWKS (`PyJWKClient`), enforce only
    when `AUTH_REQUIRED=true`, keep the open meta set (`/readyz`, `/livez`, `/openapi.json`) always reachable. `/healthz`
    is a richer report (DB + build/version) that **sits behind the auth gate**, not in the open set. See
    `references/auth-oauth2.md`.
13. **The test pyramid + the contract test.** Unit (pure domain) → integration (store + DB) → functional (HTTP via
    `httpx.ASGITransport`) → contract (emitted ≡ canonical, plus Schemathesis fuzzing). See
    `references/testing.md` and `references/openapi-contract.md`.
14. **A mechanical gate.** `ruff format --check` → `ruff check` → `mypy --strict` (or pyright) → `pytest`, all exit
    zero. Strict typing is non-negotiable: it is the correctness signal a dynamic language otherwise denies you.

## Build sequence (each step green before the next)

Work outside-in on structure but **domain-first** on logic — the rules live in the pure core, so prove them before any
HTTP exists.

1. **Scaffold + gate.** `uv init` (src layout), add deps, configure Ruff + the type checker + pytest, an app factory
   with the open probes (`/readyz`, `/livez`), `compose.yaml` (db + cache), a uv-based `Dockerfile`. Gate green on the
   skeleton.
2. **Migrations + schema.** Alembic async env; the tables/indexes/constraints your data model needs. `upgrade head` then
   `downgrade base` must round-trip cleanly.
3. **Domain core (TDD).** `decide`/`apply` (or your equivalent service functions) over frozen dataclasses + `StrEnum`,
   with a failing unit test written from each contract rule first. Type-check strict.
4. **Store.** Transactional writes, optimistic concurrency, queries/projections, a camelCase ↔ snake_case codec.
   Integration-test against a real database.
5. **Confirm the API style (see SKILL.md "Decide the API Style First").** Settle REST / RPC / mixed / split with the
   user before wiring routes; the default is mixed (resource + colon actions).
6. **REST endpoints + error handlers.** Routers, Pydantic schemas (`extra="forbid"`), the error-envelope handlers and
   the 422 reconciliation. Functional-test each.
7. **RPC command routes.** The colon-routes dispatching to `decide`, with a routing test proving the id parses without
   the `:command` suffix.
8. **Auxiliary surfaces.** Filtered list/view queries, SSE, OAuth — each behind its own tests.
9. **Contract.** Assert `app.openapi()` ≡ canonical (reconciling the generated 422), then run Schemathesis against the
   running app. Seed data idempotently; write the README; full gate green.

## Quick triage table

| Situation                                          | Default                                                                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------ |
| Building the app object                            | `create_app(...)` factory + `@asynccontextmanager` `lifespan`; inject deps     |
| Reading configuration                              | `Settings(BaseSettings)` from `pydantic-settings`; never raw `os.environ`      |
| Providing a shared resource to handlers            | `Depends(provider)` + an `Annotated[T, Depends(...)]` alias                    |
| A request body                                     | Pydantic model, `ConfigDict(extra="forbid")`, `alias` for camelCase            |
| Returning a resource                               | Serialize the domain object to a `dict`/`response_model` at the edge           |
| A resource-action command                          | `POST /res/{id}:action`, `Path(pattern=r"^[^:/]+$")`, registered before `{id}` |
| Signaling a domain failure                         | Raise a specific domain exception; a handler maps it to the envelope           |
| FastAPI's built-in 422 doesn't match your envelope | `@app.exception_handler(RequestValidationError)` rewrites the body             |
| Talking to Postgres                                | async engine + `async_sessionmaker(expire_on_commit=False)`; `text()` is fine  |
| A write that must be atomic                        | `async with session.begin():` — append + project in one transaction            |
| Concurrent-update protection                       | `UNIQUE(stream, version)`; map `IntegrityError` → 409 conflict                 |
| Which routing convention to use                    | Confirm REST / RPC / mixed / split with the user; default is mixed (resource + colon actions) |
| Live updates to clients                            | SSE; in-process LISTEN/NOTIFY for PoC/<100 conns, a GRIP proxy (Pushpin/Fastly Fanout) for production; 30s keep-alive mandatory |
| Protecting endpoints                               | Resource-server JWT dependency, gated by `AUTH_REQUIRED`; `/readyz`+`/livez`+`/openapi.json` open, `/healthz` gated |
| Testing an endpoint                                | `httpx.AsyncClient(transport=ASGITransport(app=app))` — in-process, no socket  |
| Proving the wire contract                          | `app.openapi() == canonical` test **and** Schemathesis fuzzing                 |

## Common mistakes (and the fix)

| Mistake                                                          | Fix                                                                         |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Business logic inside route handlers                             | Push it into a pure domain core; handlers only translate                    |
| `@app.on_event("startup")`                                       | `lifespan=@asynccontextmanager` passed to `FastAPI(...)`                    |
| Module-level engine/client globals constructed at import         | Build them in the factory/lifespan; inject via `Depends`                    |
| `/tasks/{task_id}` swallowing `01J…:complete`                    | Literal colon route + `Path(pattern=r"^[^:/]+$")`; register before `{id}`   |
| Accepting unknown body fields silently                           | `model_config = ConfigDict(extra="forbid")`                                 |
| Shipping FastAPI's raw 422 body when the contract defines one    | `RequestValidationError` handler that emits your envelope (keep status 422) |
| `def` handler doing async DB work / blocking call in `async def` | `async def` for I/O handlers; blocking deps as plain `def` (threadpool)     |
| Sync `psycopg`/`requests` on the event loop                      | `asyncpg` + async SQLAlchemy; `httpx.AsyncClient` for outbound              |
| Lazy-loading an ORM relationship in a response                   | Eager-load everything the response needs in the query (async forbids lazy)  |
| Separate transactions for the write and the projection           | One `async with session.begin()` around both                                |
| `pip install`, `requirements.txt`, `os.environ[...]`             | `uv add`, `uv.lock`, `pydantic-settings`                                    |
| Pydantic models leaking into the domain core                     | Convert to a domain command at the edge (`to_command()`)                    |
| Only testing happy paths over HTTP                               | Unit-test the domain exhaustively; reserve HTTP tests for the translation   |
| Version in the URL path (`/api/v1/...`)                          | Version via media type (`Accept: application/vnd...+json`) or a version header; never the path |
| Fanning out SSE from the app at scale                            | Front it with a GRIP proxy (Pushpin/Fastly Fanout); the app publishes, the proxy holds connections |
| Optional/absent SSE keep-alive                                   | Mandatory heartbeat every 30s (`EventSourceResponse(..., ping=30)`)         |

## Reference files

Read the one that matches the task; each is self-contained with idiomatic, fully-typed examples.

- `references/project-structure.md` — the layered layout, the inward-dependency rule, and why the domain core carries no
  framework imports.
- `references/bootstrap-and-config.md` — the `create_app` factory, `lifespan` (not `on_event`), `pydantic-settings`, and
  dependency injection with `Depends` + `Annotated`.
- `references/domain-core.md` — the pure domain core: `decide`/`apply` over frozen dataclasses and `StrEnum`, with the
  clock injected for deterministic timestamps.
- `references/toolchain.md` — the `pyproject.toml`/`Makefile` skeleton, Ruff/type-checker/pytest config, and the
  mechanical gate (`ruff format --check` → `ruff check` → `mypy --strict` → `pytest`).
- `references/routing-and-rpc.md` — `APIRouter` composition, REST endpoints, path/query/body parsing, the
  resource-action **colon-route** dispatch in depth, request → command mapping, response shaping.
- `references/validation.md` — Pydantic v2 at the boundary (`extra="forbid"`, aliases, validators, strict parsing,
  tri-state PATCH via `model_fields_set`).
- `references/errors.md` — the error envelope, the domain exception hierarchy, wiring the exception handlers, and the
  FastAPI **422 reconciliation**.
- `references/persistence.md` — async SQLAlchemy 2.0 + asyncpg, sessions, transactional writes, optimistic concurrency,
  projections, querying, and Alembic async migrations.
- `references/sse.md` — server-sent events: the in-process Postgres `LISTEN/NOTIFY` PoC tier (`SseHub`,
  `EventSourceResponse(ping=30)`, backfill, `Last-Event-ID` resume), the mandatory 30s keep-alive, and the GRIP-proxy
  (Pushpin/Fastly Fanout) production path.
- `references/auth-oauth2.md` — OAuth 2.0 / OIDC resource-server JWT validation with JWKS, FastAPI security utilities and
  scopes, the `AUTH_REQUIRED` gate, and testing auth.
- `references/openapi-contract.md` — the emitted-OpenAPI ≡ canonical contract test, route coverage, and Schemathesis
  property-based fuzzing.
- `references/testing.md` — the pytest pyramid, `pytest-asyncio`, `httpx.ASGITransport`, fixtures, the unit/integration/
  functional layers, and what not to test.
- `references/observability-deployment.md` — liveness/readiness probes and structured logging, plus the `Dockerfile` and
  `compose.yaml` deployment skeleton.

## Pre-flight self-check

Before calling a FastAPI change done:

- [ ] `ruff format --check` and `ruff check` are clean; the type checker passes **strict** with zero errors.
- [ ] `pytest` is green across unit / integration / functional / contract; error paths are tested, not just happy paths.
- [ ] Business logic lives in the pure domain core; handlers only parse, dispatch, and serialize.
- [ ] Every request body is a Pydantic model with `extra="forbid"`; wire aliases are correct.
- [ ] Every failure maps to the single error envelope, including FastAPI's reconciled 422.
- [ ] Resource-action routes use the colon pattern and parse the id without the `:command` suffix.
- [ ] Writes are transactional; optimistic-concurrency conflicts surface as 409.
- [ ] Dependencies are injected via `Depends`; the app is built by a factory with a `lifespan`; no import-time I/O.
- [ ] `/readyz` + `/livez` + `/openapi.json` stay open; `/healthz` (the richer report) is behind the auth gate.
- [ ] Any SSE stream sends a mandatory keep-alive every 30s; in-process LISTEN/NOTIFY is labeled PoC, a GRIP proxy is the production path.
- [ ] `app.openapi()` matches the canonical spec; Schemathesis runs clean against the live app.
- [ ] New dependencies were added with `uv add` (latest resolved, not hand-pinned) and `uv.lock` is committed.
