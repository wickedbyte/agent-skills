# Observability and Deployment

The cross-cutting concerns that make the service operable: structured logs, liveness/readiness probes, and a lean,
multi-stage container image with the Postgres it owns.

## Logging

Use `nestjs-pino` for structured JSON to stdout. Configure the level from env, silence it in tests, and let request
logging come from `pino-http` (wired by `LoggerModule.forRoot`). Log error paths and useful info/debug; **do not
unit-test logging** — it is observability, not behavior.

```ts
LoggerModule.forRoot({
    pinoHttp: {
        level: process.env.LOG_LEVEL ?? "info",
        redact: ["req.headers.authorization"], // never log bearer tokens
    },
});
```

Redaction of the `authorization` header is not optional once auth is enabled — bearer tokens must never reach the log
stream.

## Two probes, two audiences

**Two probes, two audiences.** `/readyz` answers "can I serve traffic right now?" for the load balancer and
readiness gate — a shallow dependency check (a `SELECT 1`-class ping), 200 or 503, and it stays **open**
(the balancer carries no token). `/healthz` answers "am I healthy?" with a richer report — component and
dependency status, build/version — meant for operators and dashboards. Because that detail leaks internal
topology, **`/healthz` sits behind authentication**, not in the always-open set. Keep `/openapi.json` open.
If an orchestrator needs a liveness check, point it at an open, bodyless `/livez` (or reuse `/readyz`) that
returns 200 — never expose the detailed `/healthz` publicly.

Concretely:

- `GET /readyz` — **readiness, open, shallow**: returns 200 only when migrations have run and the DB (and any cache)
  answer a `SELECT 1`; 503 otherwise. This is what gates traffic and what `compose` `depends_on … service_healthy`
  should poll. No token required.
- `GET /livez` — **liveness, open, bodyless**: returns 200 whenever the process is up, no dependency checks, no body —
  a slow DB must not make the orchestrator kill a healthy process.
- `GET /healthz` — **rich report, gated**: returns the DB ping result plus component/dependency status and
  build/version, behind the auth gate (it leaks internal topology). Wire it as an ordinary authenticated route, not a
  meta route.

```ts
@Controller()
export class HealthController {
    constructor(
        private readonly store: Store,
        @Inject(APP_CONFIG) private readonly config: AppConfig,
    ) {}

    // Open, bodyless — never gated.
    @Get("livez")
    @HttpCode(200)
    livez(): void {}

    // Open, shallow — load balancer / readiness gate.
    @Get("readyz")
    async readyz(
        @Res({ passthrough: true }) res: FastifyReply,
    ): Promise<{ status: string }> {
        const ok = await this.store.ping(); // SELECT 1
        if (!ok) {
            res.status(503);
            return { status: "not_ready" };
        }
        return { status: "ready" };
    }

    // Gated (behind the AuthGuard) — rich operator report.
    @Get("healthz")
    async healthz(): Promise<HealthReport> {
        return {
            status: "ok",
            db: (await this.store.ping()) ? "up" : "down",
            version: BUILD_VERSION,
            builtAt: BUILD_TIME,
        };
    }
}
```

`/healthz` is reached by the global `AuthGuard` like any non-open path: with `AUTH_REQUIRED=false` it answers freely,
and with the gate on it requires a token. Only `/readyz`, `/livez`, and `/openapi.json` are in the guard's open set
(see `references/auth-oauth2.md`).

## Docker + compose (the service owns its Postgres)

A multi-stage `Dockerfile` keeps the runtime image lean; the `compose.yaml` ships the service's **own** Postgres so it
runs independently and in parallel with other services.

```dockerfile
# syntax=docker/dockerfile:1
FROM node:22-slim AS build
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store pnpm install --frozen-lockfile
COPY tsconfig*.json ./
COPY src ./src
RUN pnpm build && pnpm prune --prod

FROM node:22-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
EXPOSE 8080
USER node
CMD ["node", "dist/main.js"]
```

```yaml
services:
    api:
        build: .
        environment:
            DATABASE_URL: postgres://app:app@postgres:5432/app
            AUTH_REQUIRED: "false"
        ports: ["8080:8080"]
        depends_on:
            postgres: { condition: service_healthy }
        healthcheck:
            test:
                [
                    "CMD",
                    "node",
                    "-e",
                    "fetch('http://localhost:8080/readyz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
                ]
            interval: 5s
            retries: 12
    postgres:
        image: postgres:17-alpine
        environment:
            { POSTGRES_USER: app, POSTGRES_PASSWORD: app, POSTGRES_DB: app }
        healthcheck:
            test: ["CMD-SHELL", "pg_isready -U app -d app"]
            interval: 3s
            retries: 10
```
