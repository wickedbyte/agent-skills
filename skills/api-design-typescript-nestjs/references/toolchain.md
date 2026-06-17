# Toolchain — Dependencies, Config, and the Gate

**Detect and respect the project's runner first.** In an existing repo, the package manager is whatever the committed
lockfile says (`package-lock.json` → npm, `yarn.lock` → yarn, `bun.lockb` → bun, `pnpm-lock.yaml` → pnpm), and if the
project drives its tools through `docker compose`, a `Makefile`, or a task runner, invoke them that way. Everything
below is the **greenfield default** — `pnpm` and a plain `Makefile` for a brand-new service — not a reason to migrate a
working project off its manager.

The toolchain has one job beyond building the app: **hold the line against TypeScript drift.** The ecosystem tolerates
`any`, loose configs, and stale pins; an agentic build will drift toward all three unless the gate forbids them. Strict
`tsconfig`, an ESLint rule that makes `any` an error, and `tsc --noEmit` in CI are the guardrails.

## Resolving dependencies — latest, verified, never copied

**Do not copy version numbers from this skill, the example repo, or a blog.** For every package: install the current
release, read its changelog for breaking changes, and verify against the running API.

```bash
pnpm add @nestjs/common @nestjs/core @nestjs/platform-fastify fastify reflect-metadata \
    zod kysely pg rxjs jose ulidx nestjs-pino pino
pnpm add -D typescript @types/node @types/pg vitest @nestjs/testing supertest @types/supertest \
    @testcontainers/postgresql unplugin-swc @swc/core eslint typescript-eslint @eslint/js prettier
```

Why "latest, verified" is not optional here:

- **Majors change defaults.** Zod 4 reorganized error formatting and APIs; Kysely went ESM-only; Vitest moved its
  default transformer; TypeScript 6 turned `moduleResolution: node` and `baseUrl` into hard errors. A version copied
  from six months ago can silently change behavior or refuse to build.
- **ESM is load-bearing.** Several modern cores are ESM-only. The project must be ESM end to end (`"type": "module"`,
  `module: "nodenext"`, `.js` import specifiers). Don't fight this by downgrading a core dependency — the cross-cutting
  rule is **never downgrade language/framework/test-runner to keep an outdated library.**
- **Decorator metadata is fragile across transformers.** NestJS DI relies on `emitDecoratorMetadata`. `tsc` does it;
  your test transformer must too (see Vitest below).

Use the project's package manager — the lockfile decides (`package-lock.json`/`yarn.lock`/`bun.lockb`/`pnpm-lock.yaml`);
`pnpm` is the greenfield default. Whichever it is, commit the lockfile and run the frozen/immutable install in CI
(`--frozen-lockfile` for pnpm, `npm ci`, `yarn --immutable`, `bun install --frozen-lockfile`). The NestJS transitive
tree is large — that is the cost of the DI layering; keep an `audit` step in CI and avoid adding more surface than the
contract needs.

## `package.json` scripts

```json
{
    "type": "module",
    "scripts": {
        "build": "tsc -p tsconfig.build.json",
        "start": "node dist/main.js",
        "start:dev": "node --watch dist/main.js",
        "fmt": "prettier --write .",
        "fmt:check": "prettier --check .",
        "lint": "eslint .",
        "lint:fix": "eslint . --fix",
        "types": "tsc --noEmit",
        "test": "vitest run"
    }
}
```

## Strict `tsconfig.json`

```json
{
    "compilerOptions": {
        "target": "ES2023",
        "module": "nodenext",
        "moduleResolution": "nodenext",
        "outDir": "dist",
        "rootDir": "src",

        "strict": true,
        "noUncheckedIndexedAccess": true,
        "exactOptionalPropertyTypes": true,
        "noImplicitOverride": true,
        "useUnknownInCatchVariables": true,

        "experimentalDecorators": true,
        "emitDecoratorMetadata": true,

        "esModuleInterop": true,
        "skipLibCheck": true,
        "sourceMap": true,
        "declaration": false
    }
}
```

Notes:

- `experimentalDecorators` + `emitDecoratorMetadata` are required for NestJS DI to read constructor parameter types.
- `noUncheckedIndexedAccess` + `exactOptionalPropertyTypes` are the two flags that catch the most real boundary bugs;
  keep them on even though they cost a few annotations.
- ESM means import specifiers carry `.js` even though the source is `.ts` (`import { AppModule } from "./app.module.js"`).
  This is correct under `nodenext` and trips up newcomers — it is not a mistake.
- A separate `tsconfig.build.json` extends this, sets `rootDir: src`, and excludes `test/` so tests don't ship in
  `dist/`.

## ESLint flat config — make `any` an error

ESLint 10 uses flat config. Enable type-checked rules with `projectService`, and turn `no-explicit-any` to `error` —
this is the single most important lint rule in the project.

```js
import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
    { ignores: ["dist/**", "coverage/**"] },
    js.configs.recommended,
    ...tseslint.configs.recommendedTypeChecked,
    {
        languageOptions: {
            parserOptions: {
                projectService: true,
                tsconfigRootDir: import.meta.dirname,
            },
        },
        rules: {
            "@typescript-eslint/no-explicit-any": "error",
            "@typescript-eslint/no-floating-promises": "error",
            "@typescript-eslint/consistent-type-imports": "error",
            "@typescript-eslint/return-await": ["error", "in-try-catch"],
        },
    },
);
```

Prettier handles formatting only (`singleQuote`, `trailingComma: "all"`, `printWidth: 100` is a reasonable house style);
keep it out of lint logic so the two tools don't fight.

## Vitest + decorator metadata

NestJS DI needs decorator metadata at test time. Vitest's default transformer does not emit it, so add `unplugin-swc`
with the legacy-decorator + metadata flags. Without this, every `Test.createTestingModule(...)` fails to resolve
providers.

```ts
import swc from "unplugin-swc";
import { defineConfig } from "vitest/config";

export default defineConfig({
    plugins: [
        swc.vite({
            jsc: {
                target: "es2023",
                transform: { legacyDecorator: true, decoratorMetadata: true },
            },
        }),
    ],
    test: {
        globals: true,
        include: ["test/**/*.{spec,e2e-spec}.ts"],
        env: { LOG_LEVEL: "silent" },
        testTimeout: 120_000, // Testcontainers can be slow on first pull
    },
});
```

## The gate (`Makefile`)

A single, mechanical gate that an agent (or CI) runs after every step. Order matters: formatter → linter → types →
tests. Each must exit zero.

```makefile
.PHONY: fmt-check lint types test gate up down

fmt-check: ; pnpm exec prettier --check .
lint:      ; pnpm exec eslint .
types:     ; pnpm exec tsc --noEmit
test:      ; pnpm exec vitest run
gate: fmt-check lint types test

up:   ; docker compose up -d --build
down: ; docker compose down -v
```

The multi-stage `Dockerfile` and the `compose.yaml` (with the service's own Postgres) live in
`references/observability-deployment.md`.

## Alternatives and trade-offs

- **`class-validator` + `class-transformer` instead of Zod.** Idiomatic Nest, integrates with `@nestjs/swagger`
  decorators out of the box, and uses the built-in `ValidationPipe`. Cost: validation lives in decorators on DTO
  classes (less composable than Zod schemas, no `z.infer` single-source). Pick this when you want generated OpenAPI from
  the same DTOs and don't mind decorator-heavy DTOs.
- **Drizzle or Prisma instead of Kysely.** Prisma gives migrations + a client from one schema (heavier runtime, its own
  engine); Drizzle is closer to SQL with a migration kit. Kysely is the lightest typed-SQL option with no identity map —
  a good fit for an event store where you control every query.
- **Express adapter instead of Fastify.** Use it if you depend on Express-only middleware. Everything in this skill
  works on both adapters; Fastify is the throughput default.
- **`@nestjs/config` instead of a hand-rolled Zod loader.** Fine, but still validate the schema (it supports a
  `validate` hook) — never read `process.env` ad hoc across the codebase.
