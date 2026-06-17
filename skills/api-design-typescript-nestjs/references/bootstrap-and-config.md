# Bootstrap and Configuration

Two small files set the tone for the whole service: `main.ts` (how the process starts, logs, and stops) and `config.ts`
(how untyped environment becomes a trusted, injectable value). Keep both tiny and boring — they are infrastructure, not
a place for cleverness.

## `main.ts`

```ts
import "reflect-metadata";
import { NestFactory } from "@nestjs/core";
import {
    FastifyAdapter,
    type NestFastifyApplication,
} from "@nestjs/platform-fastify";
import { Logger } from "nestjs-pino";
import { AppModule } from "./app.module.js";
import { APP_CONFIG, type AppConfig } from "./config/config.js";

async function bootstrap(): Promise<void> {
    const app = await NestFactory.create<NestFastifyApplication>(
        AppModule,
        new FastifyAdapter(),
        { bufferLogs: true },
    );

    // Route Nest's own framework logs through pino (structured JSON on stdout).
    app.useLogger(app.get(Logger));

    // Let OnModuleDestroy / OnApplicationShutdown run on SIGTERM/SIGINT.
    app.enableShutdownHooks();

    const { port } = app.get<AppConfig>(APP_CONFIG);
    await app.listen({ port, host: "0.0.0.0" });
}

void bootstrap();
```

Line by line, the load-bearing parts:

- **`import "reflect-metadata"` first.** DI reads decorator metadata at runtime; this import must execute before any
  decorated class is constructed. It belongs at the very top of the entry file.
- **`bufferLogs: true` + `useLogger`.** Buffers framework logs until the real logger is resolved, then routes everything
  through pino so you get one structured JSON stream from the first line. Without this, early boot logs use the default
  console logger.
- **`enableShutdownHooks()`.** Required for graceful shutdown — it's what lets the SSE hub close its `LISTEN`
  connection, the pool drain, and in-flight requests finish. Pair it with lifecycle hooks (below).
- **`host: "0.0.0.0"`.** Bind all interfaces so the container is reachable; `127.0.0.1` (Fastify's default) is not
  reachable from outside the container.
- **`void bootstrap()`.** The top-level call is a floating promise by nature; `void` makes that explicit and satisfies
  `no-floating-promises`.

Keep the adapter construction trivial. Add Fastify options here only when you actually need them (e.g. a custom
`bodyLimit`, `trustProxy`, or `genReqId`):

```ts
new FastifyAdapter({ bodyLimit: 1_048_576, trustProxy: true });
```

Do **not** reach for `app.useGlobalPipes(new ValidationPipe())` when you validate with per-route Zod pipes — that pipe
is for class-validator DTOs and will do nothing useful for Zod schemas. Pick one validation strategy (see
`references/validation.md`).

## Lifecycle hooks for clean startup and shutdown

Anything that opens a long-lived resource implements the lifecycle interfaces so `enableShutdownHooks()` can tear it
down deterministically. The SSE hub is the canonical example — it connects a dedicated `LISTEN` client on boot and
closes it on shutdown:

```ts
@Injectable()
export class EventHub implements OnApplicationBootstrap, OnApplicationShutdown {
    async onApplicationBootstrap(): Promise<void> {
        await this.connectListener();
    }
    async onApplicationShutdown(): Promise<void> {
        this.shuttingDown = true;
        await this.client?.end().catch(() => undefined);
        this.subject.complete();
    }
}
```

Run migrations on boot from the DB module's `onApplicationBootstrap` (see `references/persistence.md`) so a freshly
started container is immediately ready — the readiness probe should only report ready once migrations have applied and
the pool answers a `SELECT 1`.

## Configuration — validate env once, inject by token

Environment variables are an untyped boundary like any other: parse them through a schema at startup so a missing or
malformed required value fails **fast at boot**, not at the first request that happens to need it.

```ts
import { z } from "zod";

export interface AppConfig {
    readonly port: number;
    readonly databaseUrl: string;
    readonly authRequired: boolean;
    readonly oidcJwksUri: string | null;
    readonly oidcIssuer: string | null;
    readonly oidcAudience: string | null;
}

export const APP_CONFIG = Symbol("APP_CONFIG");

const envSchema = z.object({
    PORT: z.coerce.number().int().positive().default(8080),
    DATABASE_URL: z.string().min(1),
    AUTH_REQUIRED: z.enum(["true", "false"]).default("false"),
    OIDC_JWKS_URI: z.string().url().optional(),
    OIDC_ISSUER: z.string().min(1).optional(),
    OIDC_AUDIENCE: z.string().min(1).optional(),
});

export function loadConfig(env: NodeJS.ProcessEnv): AppConfig {
    const parsed = envSchema.parse(env);
    return {
        port: parsed.PORT,
        databaseUrl: parsed.DATABASE_URL,
        authRequired: parsed.AUTH_REQUIRED === "true",
        oidcJwksUri: parsed.OIDC_JWKS_URI ?? null,
        oidcIssuer: parsed.OIDC_ISSUER ?? null,
        oidcAudience: parsed.OIDC_AUDIENCE ?? null,
    };
}
```

Design choices worth keeping:

- **`AppConfig` is a `readonly` interface, not the raw parsed object.** The boundary normalizes: `"true"`/`"false"`
  strings become a `boolean`; optional strings become `T | null` (present-but-empty), distinct from absent. Downstream
  code never re-parses env.
- **`z.coerce.number()` for numeric env**, because every env var arrives as a string.
- **Validate URLs** (`z.string().url()`) so a typo in the JWKS URI fails at boot.
- **Inject by `Symbol` token**, since `AppConfig` is a plain value, not a class.

### The config module (global)

```ts
@Global()
@Module({
    providers: [
        { provide: APP_CONFIG, useFactory: () => loadConfig(process.env) },
    ],
    exports: [APP_CONFIG],
})
export class ConfigModule {}
```

`@Global()` means every feature can `@Inject(APP_CONFIG)` without re-importing the module. Read config through DI, never
by touching `process.env` deep in a service — the one exception is the `useFactory` above and the test harness, which
sets env before the module loads.

```ts
constructor(@Inject(APP_CONFIG) private readonly config: AppConfig) {}
```

Structured logging (pino setup and redaction) and the probes — the open shallow `/readyz` + bodyless `/livez` and the
gated rich `/healthz` — live in `references/observability-deployment.md`.
