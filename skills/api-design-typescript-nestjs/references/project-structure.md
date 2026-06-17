# Project Structure

The layout exists to protect one boundary: **the pure domain core must not depend on NestJS, HTTP, or the database.**
Everything else is arrangement around that seam. A controller is a translator; a service is an orchestrator; the
domain is the application. Get the directories right and the dependency direction enforces itself.

## Directory layout

```
src/
    main.ts                     # bootstrap: Fastify adapter, logger, shutdown
    app.module.ts               # root module: imports features, wires global filter + guard
    ids.ts                      # newTaskId() / newProjectId() / newEventId() → prefixed ULID

    config/
        config.ts               # AppConfig interface + loadConfig(env) (Zod) + APP_CONFIG token
        config.module.ts        # @Global() module providing APP_CONFIG

    common/                     # cross-cutting, framework-aware, but resource-agnostic
        clock.ts                # injectable server clock (now(): Date) — the one source of time
        colon-command.ts        # splitColonCommand(raw) → { id, command }
        zod-validation.pipe.ts  # ZodValidationPipe<T>
        error-envelope.ts       # the §7 envelope shape + builders
        errors.ts               # transport-level errors (NotFoundError)
        exception.filter.ts     # global @Catch() → envelope + status
        auth.guard.ts           # OIDC bearer guard, gated by AUTH_REQUIRED

    domain/                     # PURE. imports nothing from @nestjs/*, pg, fastify
        events.ts               # DomainEvent envelope + per-stream event data unions
        task.ts                 # TaskAggregate, TaskCommand union, decideTask/applyTask/foldTask
        project.ts              # ProjectAggregate, ProjectCommand union, decide/apply/fold
        dates.ts                # IsoDate / Iso8601 branded types + parse/format helpers
        patch.ts                # Patch<T> for absent-vs-null partial updates
        views.ts                # pure view predicates (today/upcoming/overdue/…)
        errors.ts               # domain errors (ValidationError, StateTransitionError)

    store/                      # the only place that knows SQL
        db.ts                   # createPool / createDb (Kysely); pg type-parser overrides
        db.module.ts            # @Global() module: PG_POOL, DB, EventStore providers
        schema.ts               # Kysely Database interface (kept in lockstep with migrations)
        event-store.ts          # append + project in one tx; load/fold; eventsAfter/getEvent
        projections.ts          # writeTaskProjection / writeProjectProjection
        codec.ts                # encode event data → jsonb, row → DomainEvent
        notify.ts               # NOTIFY_CHANNEL constant
        migrator.ts             # static migration provider + migrateToLatest/migrateDown
        migrations/0001_init.ts # DDL for events + projection tables + indexes

    modules/
        tasks/
            tasks.controller.ts          # REST: POST/GET/PATCH /tasks, GET /tasks/:id
            task-commands.controller.ts  # RPC: POST /tasks/:taskId (colon dispatch)
            tasks.service.ts             # orchestrates decide → store.commit
            task-reads.ts                # projection queries (get/list/views)
            task-serializer.ts           # aggregate/row → wire DTO + envelopes
            dto.ts                       # Zod request schemas + inferred input types
            colon-command.ts             # TASK_COMMANDS tuple + isTaskCommand guard
            tasks.module.ts
        projects/ …                      # same shape
        views/    views.controller.ts    # GET /views/* (reuses task-reads)
        events/   events.controller.ts   # @Sse('events'); event-hub.ts; event-name.ts
        meta/     health.controller.ts   # /healthz /readyz; openapi.controller.ts

    openapi.document.ts         # the served OpenAPI doc (generated or embedded)
    seed.ts                     # idempotent seed via the command path

test/
    support/app.ts              # createTestApp() — boots AppModule on a Testcontainers Postgres
    unit/                       # pure domain specs (no IO)
    integration/                # event-store / migrations / seed against real Postgres
    functional/                 # supertest HTTP specs per endpoint group + SSE
    contract/                   # emitted ≡ canonical openapi.yaml
```

## The dependency rule, made concrete

Direction of imports — each arrow may be followed, never reversed:

```
controllers ──> services ──> domain (pure)
     │              │            ▲
     │              └──> store ──┘ (store maps rows ↔ domain types; domain never imports store)
     └──> common (pipes, filter, guard, envelope)
all ──> config
```

- **`domain/` is a leaf.** It may import other `domain/` modules and nothing else. If you ever need `@Injectable()`,
  `@nestjs/common`, a `pg` `Pool`, or a `FastifyRequest` inside `domain/`, the logic is in the wrong layer. Concretely:
  a reviewer should be able to `grep -rL "@nestjs" src/domain` and see every file listed.
- **Controllers never contain rules.** They validate input, call one service method, and serialize the result. A
  controller with an `if` that encodes a domain decision is a smell — push it into `decide`.
- **The store maps both directions** (`row → DomainEvent`, `aggregate → projection row`) so the domain types never leak
  SQL column names and the SQL layer never leaks into the domain.

## Modules and dependency injection

A feature module declares its controllers and providers; a global infrastructure module exports shared providers.

```ts
@Module({
    controllers: [TasksController, TaskCommandsController],
    providers: [TasksService, TaskReads],
})
export class TasksModule {}
```

The root module imports features and registers app-wide providers with the `APP_FILTER` / `APP_GUARD` tokens so a
single instance applies globally:

```ts
@Module({
    imports: [
        ConfigModule,
        DbModule,
        LoggerModule.forRoot(/* pino */),
        TasksModule,
        ProjectsModule,
        ViewsModule,
        EventsModule,
    ],
    controllers: [HealthController, OpenapiController],
    providers: [
        { provide: APP_FILTER, useClass: DomainExceptionFilter },
        { provide: APP_GUARD, useClass: AuthGuard },
    ],
})
export class AppModule {}
```

### Injection tokens for non-class providers

Config and the DB pool are not classes you `new`, so provide them under a `Symbol` token and inject by token. This
keeps them swappable in tests and explicit at the use site:

```ts
export const APP_CONFIG = Symbol("APP_CONFIG");
export const PG_POOL = Symbol("PG_POOL");
export const DB = Symbol("DB");

constructor(@Inject(DB) private readonly db: Kysely<Database>) {}
```

Mark infrastructure modules `@Global()` (config, db) so every feature can inject them without re-importing. Keep
feature modules **not** global — their providers should be reached only through their public service.

## Naming conventions

- **Files:** kebab-case, named for the principal export and its role: `tasks.controller.ts`, `event-store.ts`,
  `zod-validation.pipe.ts`. The Nest suffix convention (`.controller`, `.service`, `.module`, `.guard`, `.pipe`,
  `.filter`) is worth keeping — it makes the role greppable.
- **Specs:** `*.spec.ts` for unit/integration, `*.e2e-spec.ts` for functional, mirroring `src/` under `test/`.
- **Domain types:** `PascalCase` interfaces with `readonly` fields (`TaskAggregate`), command unions discriminated by a
  `kind` literal, event unions discriminated by a `type` literal.

## Where each contract concept lands

| Contract concept             | Home                                                             |
| ---------------------------- | ---------------------------------------------------------------- |
| A path + verb in OpenAPI     | A controller method (REST controller, or the RPC dispatcher)     |
| A request schema             | `modules/<res>/dto.ts` (Zod) — one schema per operation          |
| A response shape / envelope  | `modules/<res>/<res>-serializer.ts`                              |
| A status code                | `@HttpCode` on the method + the exception filter for error codes |
| An invariant / guard         | `decide*` in `domain/<res>.ts`, asserted by a unit test          |
| A table / index / constraint | `store/migrations/*.ts` + the `store/schema.ts` type             |
| A read model / saved view    | `modules/<res>/<res>-reads.ts` + `domain/views.ts` predicates    |
| The error envelope           | `common/error-envelope.ts` + `common/exception.filter.ts`        |
| Auth                         | `common/auth.guard.ts` + `config/`                               |
| The emitted OpenAPI          | `openapi.document.ts` + `modules/meta/openapi.controller.ts`     |

## Anti-patterns to avoid

- **A `shared/` or `utils/` junk drawer.** Name modules for what they are (`store`, `common`, `config`). A util that has
  no home usually belongs in `domain/` (if pure) or a feature module.
- **One giant `AppService`.** Each resource gets its own service; cross-resource orchestration is rare and explicit.
- **Re-exporting the whole domain through a barrel that the store and controllers both import.** Keep imports specific so
  the dependency direction stays visible to `grep` and to the reader.
- **DTO classes that double as domain types.** The wire DTO (validated input / serialized output) and the domain
  aggregate are different shapes with different lifetimes; keep them separate and convert at the boundary.
