# Testing, Linting, and Build Tooling

The four-layer quality gate, the current (mid-2026) tool ecosystem, and what each tool actually owns.

## The four layers

| Layer                | Tool                                            | What it proves                                     |
| -------------------- | ----------------------------------------------- | -------------------------------------------------- |
| Compile semantics    | `tsc --noEmit`                                  | The code typechecks against the project's tsconfig |
| Runtime behavior     | Node built-in test runner, Vitest, Playwright   | The code does what callers expect                  |
| Public type contract | `tsd`, `vitest --typecheck`, `@ts-expect-error` | Inferred and exported types match the API contract |
| Style / safety       | typescript-eslint (typed) + Prettier            | Whole classes of mistakes do not ship              |

Each layer catches things the others miss. They are not interchangeable.

## Scripts

```json
{
    "scripts": {
        "typecheck": "tsc --noEmit",
        "test": "node --test",
        "types:test": "tsd",
        "lint": "eslint .",
        "format:check": "prettier --check .",
        "format": "prettier --write ."
    }
}
```

For a library that also publishes declarations:

```json
{
    "scripts": {
        "build": "esbuild src/index.ts --bundle --platform=node --outdir=dist",
        "build:types": "tsc -p tsconfig.types.json --emitDeclarationOnly",
        "typecheck": "tsc --noEmit",
        "test": "node --test",
        "types:test": "tsd",
        "lint": "eslint .",
        "format:check": "prettier --check ."
    }
}
```

## ESLint 10 flat config

ESLint 10 (stable in 2025) uses flat config only. typescript-eslint provides shared configs and supports
`projectService` for fast typed linting without configuring `parserOptions.project` per package.

```js
// eslint.config.mjs
import { defineConfig } from "eslint/config";
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import eslintConfigPrettier from "eslint-config-prettier";

export default defineConfig(
    js.configs.recommended,
    tseslint.configs.recommendedTypeChecked,
    {
        files: ["**/*.{ts,tsx,mts,cts}"],
        languageOptions: {
            parserOptions: {
                projectService: true,
            },
        },
        rules: {
            "@typescript-eslint/consistent-type-imports": [
                "error",
                { prefer: "type-imports" },
            ],
            "@typescript-eslint/no-floating-promises": "error",
            "@typescript-eslint/no-misused-promises": "error",
            "@typescript-eslint/return-await": ["error", "in-try-catch"],
            "@typescript-eslint/no-explicit-any": "warn",
            "@typescript-eslint/strict-boolean-expressions": "error",
            "@typescript-eslint/no-extraneous-class": "error",
            "@typescript-eslint/only-throw-error": "error",
            "@typescript-eslint/prefer-nullish-coalescing": "error",
            "@typescript-eslint/prefer-optional-chain": "error",
            "@typescript-eslint/no-unnecessary-condition": "warn",
        },
    },
    eslintConfigPrettier,
);
```

Why these rules:

| Rule                                                  | What it catches                                                                |
| ----------------------------------------------------- | ------------------------------------------------------------------------------ |
| `consistent-type-imports`                             | Auto-rewrites imports that are only used as types to `import type`             |
| `no-floating-promises`                                | Promises that are not awaited / returned / `.catch()`ed / `void`-discarded     |
| `no-misused-promises`                                 | Returning a promise from a `void` callback (event handlers, `forEach`)         |
| `return-await`                                        | Missing `await` inside `try`/`catch`                                           |
| `strict-boolean-expressions`                          | Implicit truthiness on nullable values (forces explicit `!= null`, `?.`, `??`) |
| `no-extraneous-class`                                 | Static-only classes — use a module                                             |
| `only-throw-error`                                    | Throwing non-`Error` values                                                    |
| `prefer-nullish-coalescing` / `prefer-optional-chain` | `?? ` and `?.` over `\|\|` and `&&` chains                                     |
| `no-unnecessary-condition`                            | Conditions that the type system proves are always true or always false         |

`projectService: true` lets typescript-eslint discover the tsconfig automatically and run typed rules without a stale
`parserOptions.project` setup. This is the modern default.

Run `eslint-config-prettier` last so it disables every formatting rule that conflicts with Prettier.

## Prettier

```json
{}
```

Yes, empty. Prettier's value is opinionated defaults. Use a config file only when you must override something specific,
and keep it small. `.prettierignore` excludes generated output, vendored code, lockfiles.

Do not enable Prettier rules inside ESLint. ESLint owns correctness; Prettier owns formatting. Mixing them is a slow
lint and a confusing diff.

## Runtime tests

Pick one and stay with it:

- **Node's built-in test runner** (`node --test`) — stable since Node 20, zero dependencies, fine for libraries and
  small services. Use `node:test` + `node:assert/strict`.
- **Vitest** — fastest DX for apps with a Vite-based build, also offers type-level testing via `vitest --typecheck` and
  inline snapshots. Picks up `tsconfig` automatically.
- **Playwright** for browser end-to-end. Component testing with Playwright is solid now and a reasonable alternative to
  JSDOM-based suites.
- **`@vue/test-utils`** if you are testing Vue components, but pair it with Vitest.

Avoid Mocha + Chai + ts-node + a separate transpiler — every layer is something to configure.

### Node `node:test` example

```ts
import test from "node:test";
import { strict as assert } from "node:assert";
import { parsePort } from "../src/parse-port.js";

test("parses valid ports", () => {
    assert.equal(parsePort("8080"), 8080);
});

test("rejects non-numeric input", () => {
    assert.throws(() => parsePort("x"), { message: /Invalid port/ });
});
```

The runner finds files matching default patterns (`*.test.ts`, `*.spec.ts`, etc.) and runs them in worker processes.

### Vitest example

```ts
import { expect, test } from "vitest";
import { parsePort } from "../src/parse-port.js";

test("parses valid ports", () => {
    expect(parsePort("8080")).toBe(8080);
});
```

## Type-level tests

Inferred and exported types are part of the API contract. They should have their own tests.

### `// @ts-expect-error` for negative assertions

Preferred over `// @ts-ignore` because it fails the build if the expected error disappears, so the test stays honest.

```ts
import { parsePort } from "./parse-port.js";

// @ts-expect-error parsePort accepts strings only
parsePort(123);
```

### `tsd`

Dedicated type-level testing. Files named `*.test-d.ts`:

```ts
import { expectType, expectError } from "tsd";
import { first } from "./index.js";

expectType<number | undefined>(first([1, 2, 3]));
expectType<undefined>(first([]));
expectError(first("not an array"));
```

`tsd` is strict about exact match — useful for public APIs where you want a regression to fire when an inference subtly
changes.

### Vitest `--typecheck`

If you already use Vitest, `vitest typecheck` runs `*.test-d.ts` (or inline `expectTypeOf(...)`) alongside runtime
tests.

```ts
import { expectTypeOf, test } from "vitest";
import { first } from "../src/first.js";

test("first preserves T", () => {
    expectTypeOf(first([1, 2, 3])).toEqualTypeOf<number | undefined>();
});
```

## Build tooling — pick by job, not by team

| Tool                   | Role                                               | When to reach for it                                                                |
| ---------------------- | -------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `tsc`                  | Authoritative type checker and declaration emitter | Always for `--noEmit` typecheck; libraries for `--emitDeclarationOnly`              |
| esbuild                | Fast native transpiler/bundler                     | Libraries, CLIs, simple apps, fast local dev builds                                 |
| SWC                    | Rust transpiler/minifier                           | Fast transforms in supported stacks (Next.js, etc.)                                 |
| Vite 8 (with Rolldown) | App dev server + production build                  | Browser apps and app-like DX; production bundling via Rolldown by default in Vite 8 |
| Rollup                 | ESM-centric bundler                                | Library bundling, finely controlled app builds                                      |
| Rolldown               | Rust-based ESM bundler                             | Library output, also powers Vite 8 prod builds                                      |
| webpack                | Flexible dependency-graph bundler                  | Large heterogeneous apps with many asset loaders                                    |
| Bun / Deno bundlers    | Built-in tooling for their respective runtimes     | When the runtime is the constraint                                                  |

The most important architectural rule: **fast transpilation and authoritative type checking are different jobs with
different cost models**. Run them in different lanes. Vite, esbuild, SWC, and `tsc` all say this in their own docs.

A library setup usually looks like:

- Transpile: esbuild or SWC, output ESM to `dist/`.
- Type-check: `tsc --noEmit` in CI.
- Declarations: `tsc -p tsconfig.types.json --emitDeclarationOnly`.
- Package: `package.json` `exports` + `"sideEffects": false` (only if true).

An app setup usually looks like:

- Dev: Vite 8.
- Build: Vite 8 (Rolldown under the hood).
- Type-check: `tsc --noEmit` in CI (and in your editor in the background).
- Tests: Vitest.

## CI lanes

The minimal CI for a TS project:

```yaml
- run: pnpm install --frozen-lockfile
- run: pnpm typecheck # tsc --noEmit
- run: pnpm lint # eslint . (typed rules)
- run: pnpm format:check # prettier --check
- run: pnpm test # runtime tests
- run: pnpm types:test # tsd or vitest typecheck (libs)
- run: pnpm build # only when shipping
```

Run them in parallel jobs (or as parallel matrix entries) so feedback time is dominated by the slowest, not the sum.

## Git hooks

Use a lightweight pre-commit hook to keep noise out of CI:

- `prettier --write` on changed files (so formatting never blocks a review).
- `eslint --fix` on changed files (auto-fixable correctness rules).
- `tsc --noEmit` if it is fast enough; otherwise leave it to CI.

`lint-staged` + `simple-git-hooks` (or `husky` if you already use it) is the usual setup.

Do not run the whole test suite in pre-commit. That is what CI is for.

## When tests are flaky

Flakiness is a bug, not a property of "async code". Common causes:

- A test mutates state another test depends on.
- A test races on the event loop (forgotten `await`).
- A timer or animation is involved; the test relies on wall-clock duration.

Fix the underlying cause. Retries hide the bug.

## Type tests vs. runtime tests — what each one is for

A common mistake is to use `tsd` to assert behavior or `node --test` to assert types. They do not overlap.

| Question                                                           | Tool                                |
| ------------------------------------------------------------------ | ----------------------------------- |
| "Does this function return the right value?"                       | Runtime test                        |
| "Does this function's inferred return type narrow correctly?"      | Type test                           |
| "Does this throw the right error?"                                 | Runtime test (with `assert.throws`) |
| "Does this overload pick the right signature for these arguments?" | Type test                           |
| "Does this generic preserve `T`?"                                  | Type test                           |
| "Does this validator reject a malformed payload?"                  | Runtime test                        |

The right gate for a public TypeScript library is **both**.
