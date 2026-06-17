---
name: api-design-python-fastapi
description: >-
    Use when building, structuring, or testing a REST or RPC API in Python with FastAPI — scaffolding a new FastAPI
    service, implementing endpoints against an OpenAPI/Swagger specification, organizing routers / Pydantic models /
    dependencies, wiring async SQLAlchemy + asyncpg persistence and Alembic migrations, adding OAuth 2.0 / OIDC JWT
    auth, streaming server-sent events, or testing a FastAPI app against its OpenAPI contract (httpx ASGITransport,
    Schemathesis). Triggers on FastAPI, uvicorn, Pydantic v2 request/response models, `Depends()` / `Annotated`
    dependency injection, `APIRouter`, resource-action colon routes (`POST /things/{id}:action`), `pydantic-settings`,
    the app-factory + `lifespan` pattern, the error-envelope exception handlers, and the emitted-OpenAPI ≡ spec
    contract test. Use this even when the user only hands over an OpenAPI/Swagger document and asks for "a Python API",
    or does not explicitly say FastAPI. Layer it on top of `best-practices-python`, which governs language-level style.
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

## The dependency stack (add with `uv`, verify latest, never hand-pin)

Add these with `uv add` / `uv add --dev`; the lockfile records exact versions. Reach for a library only when the
feature needs it — don't install auth or SSE deps for a service that has neither.

| Concern                | Library                                     | Notes                                                         |
| ---------------------- | ------------------------------------------- | ------------------------------------------------------------- |
| Package/venv manager   | **uv**                                      | Never system `pip`/`python3`. Every command is `uv run …`.    |
| Web framework          | **fastapi**                                 | Emits OpenAPI **3.1** natively.                               |
| ASGI server            | **uvicorn[standard]**                       | `uvicorn`/`uvloop`/`httptools`; add Granian only if measured. |
| Validation / models    | **pydantic** (v2)                           | `ConfigDict(extra="forbid")` → `additionalProperties:false`.  |
| Settings               | **pydantic-settings**                       | Env-sourced `Settings`; typed, validated, no `os.environ`.    |
| DB toolkit             | **sqlalchemy[asyncio]** (2.0)               | Core `text()` is enough for an event store; ORM is optional.  |
| Async driver           | **asyncpg**                                 | Postgres; also exposes `LISTEN/NOTIFY` for SSE.               |
| Migrations             | **alembic**                                 | Async env; run out of band, never per worker.                 |
| Server-sent events     | **sse-starlette**                           | `EventSourceResponse`; pair with asyncpg `add_listener`.      |
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

See `references/project-structure.md` for the app factory, `lifespan`, settings, and dependency injection in full.

## Core defaults — apply unless the contract gives a reason not to

1. **Contract-first.** Treat the OpenAPI doc as frozen. If it looks wrong, raise it — don't quietly diverge. Decide
   early whether the app **emits** its schema (FastAPI generates it from your routes/models) or **serves a canonical
   file verbatim**; a test pins emitted ≡ canonical either way. See `references/testing-and-contract.md`.
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
   handler so the _body_ matches your envelope (status stays 422). See `references/validation-and-errors.md`.
9. **Async all the way down.** `async def` handlers, async engine, async sessions. Never call blocking I/O on the event
   loop; if a dependency is sync (e.g. a JWKS fetch), make the _dependency_ a plain `def` so FastAPI runs it in the
   threadpool.
10. **Transactional writes + optimistic concurrency.** Append/insert and update projections in **one** transaction; let
    a `UNIQUE(stream, version)` collision surface as a 409 conflict. See `references/persistence-and-events.md`.
11. **SSE via Postgres `LISTEN/NOTIFY`** when you stream: a single shared listener fans events to per-subscriber
    `asyncio.Queue`s through `EventSourceResponse`; `Last-Event-ID` backfills then goes live.
12. **OAuth 2.0 as a gated dependency.** Validate the bearer JWT against the issuer's JWKS (`PyJWKClient`), enforce only
    when `AUTH_REQUIRED=true`, keep meta endpoints (`/healthz`, `/readyz`, `/openapi.json`) always open. See
    `references/auth.md`.
13. **The test pyramid + the contract test.** Unit (pure domain) → integration (store + DB) → functional (HTTP via
    `httpx.ASGITransport`) → contract (emitted ≡ canonical, plus Schemathesis fuzzing). See
    `references/testing-and-contract.md`.
14. **A mechanical gate.** `ruff format --check` → `ruff check` → `mypy --strict` (or pyright) → `pytest`, all exit
    zero. Strict typing is non-negotiable: it is the correctness signal a dynamic language otherwise denies you.

## Build sequence (each step green before the next)

Work outside-in on structure but **domain-first** on logic — the rules live in the pure core, so prove them before any
HTTP exists.

1. **Scaffold + gate.** `uv init` (src layout), add deps, configure Ruff + the type checker + pytest, an app factory
   with `/healthz`, `compose.yaml` (db + cache), a uv-based `Dockerfile`. Gate green on the skeleton.
2. **Migrations + schema.** Alembic async env; the tables/indexes/constraints your data model needs. `upgrade head` then
   `downgrade base` must round-trip cleanly.
3. **Domain core (TDD).** `decide`/`apply` (or your equivalent service functions) over frozen dataclasses + `StrEnum`,
   with a failing unit test written from each contract rule first. Type-check strict.
4. **Store.** Transactional writes, optimistic concurrency, queries/projections, a camelCase ↔ snake_case codec.
   Integration-test against a real database.
5. **REST endpoints + error handlers.** Routers, Pydantic schemas (`extra="forbid"`), the error-envelope handlers and
   the 422 reconciliation. Functional-test each.
6. **RPC command routes.** The colon-routes dispatching to `decide`, with a routing test proving the id parses without
   the `:command` suffix.
7. **Auxiliary surfaces.** Filtered list/view queries, SSE, OAuth — each behind its own tests.
8. **Contract.** Assert `app.openapi()` ≡ canonical (reconciling the generated 422), then run Schemathesis against the
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
| Streaming events to clients                        | `sse-starlette` `EventSourceResponse` + asyncpg `add_listener` (LISTEN/NOTIFY) |
| Protecting endpoints                               | Resource-server JWT dependency, gated by `AUTH_REQUIRED`; meta always open     |
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

## Reference files

Read the one that matches the task; each is self-contained with idiomatic, fully-typed examples.

- `references/project-structure.md` — layered layout, the `create_app` factory, `lifespan`, `pydantic-settings`,
  dependency injection with `Annotated`, the pure domain core, the `uv`/Docker/Makefile toolchain.
- `references/routing-and-rpc.md` — `APIRouter` composition, REST endpoints, path/query/body parsing, the
  resource-action **colon-route** dispatch in depth, request → command mapping, response shaping.
- `references/validation-and-errors.md` — Pydantic v2 at the boundary (`extra="forbid"`, aliases, validators, strict
  parsing), the error envelope, exception handlers, and the FastAPI **422 reconciliation**.
- `references/persistence-and-events.md` — async SQLAlchemy 2.0 + asyncpg, sessions, transactional writes, optimistic
  concurrency, projections, Alembic async migrations, and SSE over `LISTEN/NOTIFY`.
- `references/auth.md` — OAuth 2.0 / OIDC resource-server JWT validation with JWKS, FastAPI security utilities and
  scopes, the `AUTH_REQUIRED` gate, and testing auth.
- `references/testing-and-contract.md` — the pytest pyramid, `pytest-asyncio`, `httpx.ASGITransport`, fixtures, the
  emitted-OpenAPI ≡ canonical contract test, route coverage, and Schemathesis property-based fuzzing.

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
- [ ] `app.openapi()` matches the canonical spec; Schemathesis runs clean against the live app.
- [ ] New dependencies were added with `uv add` (latest resolved, not hand-pinned) and `uv.lock` is committed.
      </content>
      </invoke>
