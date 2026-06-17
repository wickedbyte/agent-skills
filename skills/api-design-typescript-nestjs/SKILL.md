---
name: api-design-typescript-nestjs
description: >-
    Use when building, structuring, or testing a REST or RPC HTTP API in TypeScript with NestJS — implementing an
    OpenAPI 3.x contract, or scaffolding controllers, modules, providers, DTOs, pipes, guards, filters, or `@Sse()`
    streams. Covers resource-action RPC routes (`POST /resource/{id}:command`), Zod (or class-validator) request
    validation, a single error envelope, command/event-sourced service layers with optimistic concurrency, OAuth 2.0 /
    OIDC bearer auth, Postgres persistence, Server-Sent Events (SSE), and asserting emitted OpenAPI ≡ canonical. Triggers on
    `@nestjs/*` packages, the Fastify/Express adapter, or a Nest project — use it even when the user does not say
    "NestJS best practices". Builds on `best-practices-typescript`.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# Build a REST / RPC API with NestJS

This skill is a playbook for building a **production-grade, strictly-typed, thoroughly-tested HTTP API in NestJS** —
the kind of service that fronts an OpenAPI contract and has to pass conformance testing against it. It targets NestJS
as it stands in mid-2026 (NestJS 11 on the **Fastify adapter**, TypeScript 6 strict, ESM, Zod 4 at the boundary,
Vitest 4, `pnpm`). Read it **alongside `best-practices-typescript`** — every rule there (strict tsconfig, `readonly`
data, discriminated unions, `unknown` at boundaries, no `any`, type-only imports, no floating promises) still applies;
this skill adds the NestJS-, HTTP-, and contract-specific layer on top.

The goal: given an OpenAPI description, you can stand up the **whole skeleton** — layout, dependencies, routing,
validation, auth, errors, persistence, streaming, and the test harness — so the only thing left to write is the
business logic unique to the domain.

## The One Idea

**A NestJS API is a thin, typed HTTP shell around a framework-free core.** Controllers, pipes, guards, filters, and
modules exist to move data across the HTTP boundary and wire dependencies together — nothing more. The actual rules of
the domain live in plain functions and classes that never import `@nestjs/*`, never touch a request object, and can be
unit-tested with no server and no database. NestJS is the adapter; your domain is the application.

Two consequences drop out of that idea, and they shape everything below:

1. **The boundary is where correctness is enforced, and it is narrow.** Untyped bytes arrive (JSON body, query string,
   path param, header, bearer token) and must be validated into precise domain types _once_, at the edge, with a schema
   — and every failure must leave through _one_ error envelope. Inside the boundary everything is already typed and
   trusted.
2. **The contract is the source of truth, not the code.** The OpenAPI document is frozen first; the implementation
   conforms to it. You assert that conformance two ways — an in-repo test that the **emitted** OpenAPI equals the
   canonical document, and an external fuzzer (Schemathesis) that drives the **running** server against it. Code that
   passes both is contract-correct; code that merely compiles is not.

## When to Use This Skill

Use it for any of:

- Scaffolding a new NestJS service, or adding endpoints/modules to an existing one
- Implementing an API from an OpenAPI 3.x spec (deriving layout, DTOs, routes, responses)
- Designing controllers, REST resources, or **resource-action RPC** routes (`POST /tasks/{id}:complete`)
- Wiring request validation (Zod or class-validator), a global exception filter, or an auth guard
- Adding OAuth 2.0 / OIDC bearer-token protection as a toggleable gate
- Adding a Server-Sent Events stream, especially backed by Postgres `LISTEN/NOTIFY`
- Standing up the test pyramid: pure unit tests, integration tests against a real DB, functional HTTP tests, and the
  OpenAPI contract test
- Choosing the dependency set and toolchain (adapter, query layer, validation, IDs, logging)

Do not use it for: front-end React/Next work (use the React/Next skills), non-Nest Node frameworks (Express-only,
Fastify-only, Hono), or pure TypeScript questions with no HTTP/Nest dimension (use `best-practices-typescript`).

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
  task runner. Detect the package manager from the lockfile and use it — `npm`/`yarn`/`bun`/`pnpm`
  (`package-lock.json`/`yarn.lock`/`bun.lockb`/`pnpm-lock.yaml`). `pnpm` is only the greenfield default;
  never force a project off its manager. If the project runs its tooling through `docker` / `docker compose` or a custom
  `Makefile`/script/task runner, invoke the tools that way instead of calling them directly. The named
  tools below are greenfield defaults — never a reason to migrate a project off what it already uses.

## Workflow — from an OpenAPI spec to a passing service

Build in this order. Each step has a gate (`format → lint → typecheck → test`); do not advance until it is green. This
is the same discipline whether you drive it by hand or dispatch steps to subagents.

1. **Read the contract first.** The OpenAPI document, plus any spec/invariant doc, define every path, status code,
   request/response schema, and error shape. List the invariants you must enforce and map each to a future test name
   _before_ writing code. The contract is frozen; if it seems wrong, that is a finding to raise, not a thing to edit
   around.
2. **Scaffold + toolchain.** Project layout (`references/project-structure.md`), dependencies pulled in at their
   **latest** versions (`references/toolchain.md`), strict `tsconfig`, ESLint flat config, Prettier, Vitest, a
   `Makefile`/scripts gate, and a `Dockerfile` + `compose.yaml` with the service's own Postgres
   (`references/observability-deployment.md`). Prove `GET /readyz` returns 200.
3. **Persistence + migrations.** Versioned migrations for every table/index/constraint; a typed query layer; a
   migrate-on-boot module (`references/persistence.md`).
4. **Domain core, test-first.** The pure functions/types that encode the rules — no Nest, no IO. Write the failing test
   from each invariant, then implement (`references/domain-core.md`).
5. **Confirm the API style (see SKILL.md).** Decide REST / RPC / mixed / split before wiring routes — follow the
   contract if it encodes one, otherwise ask the user (`references/routing-and-rpc.md`).
6. **The boundary: routing + validation + errors.** Controllers (REST then the colon-command RPC dispatcher), one
   validation schema per request, and the global exception filter that maps every error to the envelope
   (`references/routing-and-rpc.md`, `references/validation.md`, `references/errors.md`).
7. **Streaming.** `@Sse()` fed by a `LISTEN/NOTIFY` hub for the PoC tier (a GRIP proxy at scale), with `Last-Event-ID`
   resume and a mandatory 30-second keep-alive (`references/sse.md`).
8. **Auth scaffolding.** An OIDC resource-server guard gated by `AUTH_REQUIRED`, default off (`references/auth-oauth2.md`).
9. **OpenAPI + contract test.** Serve `/openapi.json`; assert emitted ≡ canonical; run the external fuzzer
   (`references/openapi-contract.md`).
10. **Seed, README, full gate, conformance.** Idempotent seed, docs, the whole gate green, fuzzer passing.

## Core Defaults — apply unless the task gives a specific reason not to

### 1. Run on the Fastify adapter, bootstrap minimally

Create the app with `NestFastifyApplication` and a `FastifyAdapter`. Fastify is faster and JSON-Schema-friendly; Nest's
programming model is identical to Express. Keep `main.ts` tiny — buffer logs, route them through a structured logger,
enable shutdown hooks, bind `0.0.0.0`:

```ts
import "reflect-metadata";
import { NestFactory } from "@nestjs/core";
import {
    FastifyAdapter,
    type NestFastifyApplication,
} from "@nestjs/platform-fastify";
import { Logger } from "nestjs-pino";
import { AppModule } from "./app.module.js";

async function bootstrap(): Promise<void> {
    const app = await NestFactory.create<NestFastifyApplication>(
        AppModule,
        new FastifyAdapter(),
        { bufferLogs: true },
    );
    app.useLogger(app.get(Logger));
    app.enableShutdownHooks();
    await app.listen({ port: 8080, host: "0.0.0.0" });
}

void bootstrap();
```

Note `.js` import specifiers: the project is ESM (`"type": "module"`, `module: "nodenext"`). See
`references/bootstrap-and-config.md`.

### 2. One module per resource; keep the domain Nest-free

A module owns a resource: its controllers, its service, its read/serialization helpers. Cross-cutting concerns
(exception filter, auth guard, validation pipe, clock, config, DB) live in `common/`, `config/`, and a global
`store`/`db` module. The `domain/` directory imports **nothing** from `@nestjs/*` — it is pure. This is the seam that
makes the core testable in microseconds and keeps DI doing only what DI is good at. See `references/project-structure.md`.

### 3. Validate at the boundary with a schema; trust nothing the framework hands you

Every request body, query, and param is `unknown` until a schema validates it. Default to **Zod** `z.strictObject(...)`
(unknown keys rejected → mirrors OpenAPI `additionalProperties: false`) applied through a one-line pipe:

```ts
export class ZodValidationPipe<T> implements PipeTransform<unknown, T> {
    constructor(private readonly schema: ZodType<T>) {}
    transform(value: unknown): T {
        return this.schema.parse(value);
    }
}

@Post()
@HttpCode(201)
async create(@Body(new ZodValidationPipe(createTaskSchema)) body: CreateTaskInput) {
    return taskEnvelope(await this.tasks.createTask(body));
}
```

A `ZodError` thrown here is caught by the global filter and rendered as the validation envelope. One schema gives you
the runtime check **and** the static type (`z.infer`). See `references/validation.md`.

### 4. Dispatch resource-action RPC by splitting on the last colon

Routers (Fastify's `find-my-way`, Express) treat `:` as a path-parameter delimiter, so `POST /tasks/{id}:complete`
cannot be declared as a literal route. Declare a single catch route `@Post(":taskId")`, then split the captured segment
on its **last** colon and dispatch — unknown/missing command → 404:

```ts
@Controller("tasks")
export class TaskCommandsController {
    constructor(private readonly tasks: TasksService) {}

    @Post(":taskId")
    @HttpCode(200)
    async dispatch(@Param("taskId") raw: string, @Body() body: unknown) {
        const { id, command } = splitColonCommand(raw);
        if (command === null || !isTaskCommand(command)) {
            throw new NotFoundError(`no such task command on ${raw}`);
        }
        return taskEnvelope(await this.tasks.runCommand(id, command, body));
    }
}
```

Unit-test that `task_01J…:complete` splits to `(task_01J…, "complete")` and that a bare id is not split. See
`references/routing-and-rpc.md`.

### 5. Keep the domain pure: `decide` / `apply`, exhaustive over a `never`

Model commands and (for event-sourced domains) events as discriminated unions. A pure `decide(state, command, now)`
validates guards and returns the resulting event(s)/changes; a pure `apply(state, event)` folds state forward. Make
both `switch`es exhaustive with a `never` default so a forgotten variant is a **compile error**:

```ts
export function decideTask(
    state: TaskAggregate,
    command: TaskCommand,
    now: Date,
): readonly TaskEvent[] {
    switch (command.kind) {
        case "capture":
            return decideCapture(command);
        case "complete":
            ensureNotTerminal(state, "complete");
            return [
                {
                    type: "TaskCompleted",
                    completedAt: command.completedAt ?? isoNow(now),
                },
            ];
        // …every other command…
        default: {
            const unreachable: never = command;
            return unreachable;
        }
    }
}
```

The server clock is the only clock; pass `now` in, never read it inside the core. See `references/domain-core.md`.

### 6. Write through events in one transaction; project read-your-writes

The command path is: **load stream → fold to current state → `decide` (guards) → append event(s) with the expected
version → update the read-model projection(s) in the _same transaction_ → publish for SSE → return the projection.**
Optimistic concurrency falls out of a `UNIQUE (stream_id, version)` constraint (stale append → 409). Because the
projection is written in the same transaction, the response already reflects the change. See `references/persistence.md`.

### 7. One error envelope, one global exception filter

Every error — validation, not-found, conflict, terminal-state, concurrency, unhandled — leaves through a single
`@Catch()` filter that maps a typed exception to `{ status, body }` where `body` is the contract's error envelope.
Domain code throws named errors (`ValidationError`, `NotFoundError`, `VersionConflictError`); the filter is the only
place that knows HTTP status codes. Never let a raw stack trace or a framework default error shape reach the client.
See `references/errors.md`.

### 8. Auth is a guard, gated by config, default off

Ship the OAuth 2.0 / OIDC **resource-server** scaffolding from day one but keep it inert: a global guard that returns
`true` when `AUTH_REQUIRED` is false, and otherwise verifies a bearer JWT against the issuer's JWKS with `jose`. The
open meta set is `/readyz`, `/livez`, and `/openapi.json`; **`/healthz` is gated** (a richer report behind auth — DB
ping + build/version). See `references/auth-oauth2.md`.

### 9. Configuration is validated env, injected by token

Parse `process.env` once through a Zod schema into a `readonly` `AppConfig`, provide it under an injection token, and
read it via DI. A missing or malformed required variable fails fast at boot, not at first request. See
`references/bootstrap-and-config.md`.

### 10. The emitted OpenAPI must equal the canonical contract

Serve the document at `/openapi.json` and keep an in-repo test asserting it equals the frozen `openapi.yaml`. Two valid
strategies: **generate** it from your schemas with `@nestjs/swagger` + a Zod bridge and tune until it matches, or
**embed-and-serve** the canonical document verbatim (matching by construction) with a drift check. Prefer
embed-and-serve when the contract is externally frozen — it removes the most fragile tuning loop. See
`references/openapi-contract.md`.

### 11. Test in four layers; drive each from an invariant

Unit (pure domain, microseconds), integration (the store against a **real** Postgres via Testcontainers), functional
(HTTP through `supertest` against the booted app), and contract (emitted ≡ canonical). TDD: write the failing test from
the invariant, then implement. Do **not** unit-test logging. See `references/testing.md`.

### 12. Pull in latest versions; never pin to stale ones

Do not copy version numbers from this skill or from any example. For each dependency, install the **current** release
through the project's package manager (the lockfile decides; `pnpm add <pkg>@latest` is the greenfield default), read
its changelog/migration notes, and verify it against the live API — the ecosystem moves
fast and majors change defaults (ESM-only packages, Zod 4, Vitest's transformer, TS strictness). Never downgrade a core
dependency (language, framework, test runner) to accommodate an outdated library. See `references/toolchain.md`.

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

## Dependency Set (resolve each to its latest release)

A typical, well-defended NestJS API pulls in roughly this set. **Names and roles are the durable part — versions are
not.** Run `<pkg>@latest` through the project's package manager (the lockfile decides:
`package-lock.json`/`yarn.lock`/`bun.lockb`/`pnpm-lock.yaml`; `pnpm` is the greenfield default) — e.g.
`pnpm add <pkg>@latest` (or `-D`) — and verify.

| Concern             | Package(s)                                                                         | Role                                                          |
| ------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Framework + adapter | `@nestjs/common` `@nestjs/core` `@nestjs/platform-fastify` `fastify`               | DI, modules, HTTP via Fastify                                 |
| Reflection          | `reflect-metadata`                                                                 | Decorator metadata for DI (import once in `main.ts`)          |
| Validation          | `zod`                                                                              | One schema → runtime check + static type at the boundary      |
| DB driver + queries | `pg` + `kysely`                                                                    | Postgres client + typed SQL builder (no ORM identity map)     |
| Streaming           | `rxjs` (+ a GRIP proxy — Pushpin / Fastly Fanout — at scale)                        | `Observable` feed for `@Sse()` (PoC tier); proxy holds connections in production |
| Auth                | `jose`                                                                             | JWKS fetch + JWT verify in the guard                          |
| IDs                 | `ulidx`                                                                            | Sortable, prefixed, opaque IDs                                |
| Logging             | `nestjs-pino` + `pino`                                                             | Structured JSON logs to stdout                                |
| Config              | `zod` (reused)                                                                     | Validate `process.env`                                        |
| Tests               | `vitest` `@nestjs/testing` `supertest` `@testcontainers/postgresql` `unplugin-swc` | Runner, Nest test harness, HTTP, real DB, decorator transform |
| Lint/format         | `eslint` `typescript-eslint` `@eslint/js` `prettier`                               | Flat-config lint (ban `any`) + formatter                      |
| Language            | `typescript` `@types/node`                                                         | Strict TS, ESM (`nodenext`)                                   |

Swap deliberately: `class-validator` + `class-transformer` instead of Zod (decorator DTOs, first-class
`@nestjs/swagger`), Drizzle/Prisma instead of Kysely, the Express adapter instead of Fastify. The skill's patterns hold
across those choices; `references/toolchain.md` covers the trade-offs.

## Quick Triage Table

| Situation                                          | Default choice                                                                   |
| -------------------------------------------------- | -------------------------------------------------------------------------------- |
| HTTP adapter                                       | Fastify (`@nestjs/platform-fastify`)                                             |
| Which routing convention to use                    | Confirm REST / RPC / mixed / split with the user; default is mixed (resource + colon actions) |
| Request validation                                 | Zod `z.strictObject` via a `ZodValidationPipe`                                   |
| `POST /res/{id}:command` routing                   | One `@Post(":id")` catch route + split-on-last-colon dispatch                    |
| Where domain rules live                            | Pure `domain/` functions — never import `@nestjs/*`                              |
| Surfacing an error                                 | `throw` a named domain error; map it in one global `@Catch()` filter             |
| Concurrency / lost-update protection               | `UNIQUE (stream_id, version)` → 409 on stale append                              |
| Read-your-writes after a command                   | Update projection in the **same transaction** as the append                      |
| Date-only field (`YYYY-MM-DD`)                     | Keep as a string; override `pg` type parser `1082` to return raw text            |
| Live updates to clients                            | SSE; in-process `LISTEN/NOTIFY` for PoC/<100 conns, a GRIP proxy (Pushpin/Fastly Fanout) for production; 30s keep-alive mandatory |
| SSE transport (PoC tier)                           | Postgres `LISTEN/NOTIFY` → RxJS `Subject` → `@Sse()`; resume via `Last-Event-ID` |
| Auth                                               | OIDC resource-server guard with `jose`, gated by `AUTH_REQUIRED` (default off)   |
| Meta endpoints open without a token                | `/readyz`, `/livez`, `/openapi.json` open; `/healthz` is gated behind auth       |
| OpenAPI doc when the contract is externally frozen | Embed canonical + serve verbatim + drift check                                   |
| OpenAPI doc when you own the contract              | Generate from schemas (`@nestjs/swagger`) and assert ≡                           |
| Testing the store / migrations                     | Real Postgres via Testcontainers, not a mock                                     |
| Testing an endpoint                                | `supertest` against the booted Fastify app                                       |
| Config access                                      | Zod-validated `AppConfig` injected by token                                      |
| ID scheme                                          | Prefixed ULID (`task_01J…`); pick one scheme and keep it                         |

## Reference Files

Read the relevant file when SKILL.md leaves a judgment call open:

- `references/project-structure.md` — Directory layout, one-module-per-resource, the Nest-free `domain/` seam, where
  controllers/services/reads/serializers/DTOs go, global vs feature modules, DI tokens.
- `references/toolchain.md` — The dependency set and how to resolve latest, strict `tsconfig` (ESM/`nodenext`), ESLint
  flat config that bans `any`, Prettier, Vitest + `unplugin-swc` decorator metadata, `pnpm`, the `Makefile` gate.
  Alternatives (class-validator, Drizzle/Prisma, Express).
- `references/bootstrap-and-config.md` — `main.ts`, Fastify adapter options, graceful shutdown, the
  Zod-validated `AppConfig` injected by token, wiring global filter/guard via `APP_FILTER`/`APP_GUARD`.
- `references/routing-and-rpc.md` — Controllers, REST resources, the colon-command dispatcher in depth, parsing path
  params without the suffix, status codes, `@HttpCode`, list/query endpoints, the routing unit test.
- `references/validation.md` — The boundary discipline, `z.strictObject`, request vs query vs param schemas, coercing
  query booleans, partial-update semantics (absent = leave, explicit `null` = clear), where format checks belong.
- `references/domain-core.md` — Aggregates as `readonly` interfaces, command/event discriminated unions, pure
  `decide`/`apply`/`fold`, exhaustiveness via `never`, guards and named errors, injecting the clock, view predicates.
- `references/persistence.md` — `pg` + Kysely setup, the date-type-parser gotcha, the event store (`append` + projections
  in one transaction), optimistic concurrency, migrations + migrate-on-boot, projection rebuild, the Valkey lock option.
- `references/sse.md` — the PoC-vs-GRIP-proxy scaling decision and the mandatory 30s keep-alive, `@Sse()` + RxJS, the
  `LISTEN/NOTIFY` hub on a dedicated connection (PoC tier), per-connection backfill + live merge + dedup, `Last-Event-ID`
  resume, event-name mapping, reconnect, shutdown, and publishing to a Pushpin/Fanout proxy in production.
- `references/errors.md` — The error envelope shape, the global `@Catch()` filter, mapping each domain error → status +
  code, validation-error field/reason extraction, never leaking stack traces, the 500 fallback.
- `references/auth-oauth2.md` — The OAuth 2.0 / OIDC resource-server model, the `jose` `createRemoteJWKSet` + `jwtVerify`
  guard, `AUTH_REQUIRED` gating, the open meta paths (`/readyz`, `/livez`, `/openapi.json`) with `/healthz` gated,
  issuer/audience checks, the security scheme in the contract,
  scope/claim checks, testing with a local JWKS.
- `references/openapi-contract.md` — Emit-vs-embed strategies, serving `/openapi.json`, the emitted ≡ canonical test,
  normalizing for comparison, and running the external Schemathesis conformance fuzzer against the container.
- `references/testing.md` — The four layers, Vitest + `unplugin-swc` config, Testcontainers for real Postgres, the
  `createTestApp` helper, `supertest` patterns, table-driven invariant tests, testing SSE, what not to test.
- `references/observability-deployment.md` — Structured pino logging and `authorization` redaction, the two-probe
  policy (open shallow `/readyz` + `/livez`, gated rich `/healthz`), the multi-stage `Dockerfile`, and the
  `compose.yaml` with the service's own Postgres.

## Common Mistakes (and the fix)

| Mistake                                                                        | Fix                                                                                          |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Declaring `@Post(":id\\:complete")` and fighting the router over the colon     | One `@Post(":id")` catch route + `splitColonCommand` on the last `:` + dispatch              |
| Splitting the command on the **first** colon                                   | Split on the **last** `:` so IDs that contain colons survive; test both cases                |
| Business logic inside controllers (or `@nestjs/*` imported in `domain/`)       | Controllers only marshal HTTP; rules live in pure `domain/` functions                        |
| Trusting `@Body()` / `@Query()` as a typed DTO without a runtime schema        | Validate every input through a Zod schema pipe; the type is a _claim_ until checked          |
| `z.object(...)` for a request body                                             | `z.strictObject(...)` so unknown keys are rejected (matches `additionalProperties: false`)   |
| Per-controller `try/catch` translating errors to responses                     | Throw named domain errors; map them once in the global `@Catch()` filter                     |
| `enableCors`/`ValidationPipe`/version pins copied from a blog without checking | Resolve latest, read the changelog, verify against the running API                           |
| Reading `pg` `date` columns as `Date` (shifts `YYYY-MM-DD` across TZs)         | Override the `date` type parser (OID `1082`) to return the raw string                        |
| Updating the projection in a _separate_ transaction from the append            | Append + project in **one** transaction so reads-your-writes (and the SSE notify) are atomic |
| Reading `Date.now()` inside the domain core                                    | Pass `now: Date` in from the edge; the core stays pure and deterministic                     |
| Tuning `@nestjs/swagger` for hours to match a frozen external contract         | Embed the canonical document and serve it verbatim; add a drift check                        |
| Mocking Postgres in store/migration tests                                      | Use a real Postgres via Testcontainers; mocks hide constraint/concurrency bugs               |
| Leaving `AUTH_REQUIRED` un-scaffolded "until later"                            | Ship the inert guard now; flipping the env is the only change needed to enforce              |
| Forgetting `reflect-metadata` / SWC decorator metadata in tests                | Import `reflect-metadata` in `main.ts`; configure `unplugin-swc` so Vitest emits DI metadata |
| Version in the URL path (`/api/v1/...`)                                        | Version via media type (`Accept: application/vnd...+json`) or a version header; never the path |
| Fanning out SSE from the app at scale                                          | Front it with a GRIP proxy (Pushpin/Fastly Fanout); the app publishes, the proxy holds connections |
| Optional/absent SSE keep-alive                                                 | Mandatory heartbeat every 30s                                                                |

## Pre-Commit Self-Check

Before saying "done" on a NestJS API change, verify:

- [ ] `format → lint → typecheck → test` all exit zero. `eslint` reports **no `any`**.
- [ ] Every controller method validates its body/query/params through a schema; nothing trusts a raw `@Body()` type.
- [ ] Request schemas are `strictObject` (or otherwise reject unknown keys) to match `additionalProperties: false`.
- [ ] `domain/` imports nothing from `@nestjs/*` and reads no clock/IO; the clock is passed in.
- [ ] Resource-action routes dispatch by splitting on the **last** colon, with a unit test for the split.
- [ ] Every error path leaves through the single global exception filter and the contract's error envelope.
- [ ] Command writes append events and update projections in **one** transaction; stale versions yield 409.
- [ ] Discriminated `switch`es over commands/events are exhaustive with a `never` default.
- [ ] The auth guard is wired, gated by `AUTH_REQUIRED`, leaves `/readyz` `/livez` `/openapi.json` open, and **gates
      `/healthz`** behind auth.
- [ ] Every SSE stream emits a keep-alive heartbeat at least every 30s; production fan-out goes through a GRIP proxy,
      not the app process.
- [ ] `GET /openapi.json` is served and an in-repo test asserts it equals the canonical contract.
- [ ] Store/migration tests run against a real Postgres; HTTP tests run against the booted app.
- [ ] Dependencies were resolved to their **latest** releases and verified — no stale pins copied from examples.
