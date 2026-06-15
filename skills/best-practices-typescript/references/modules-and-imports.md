# Modules and Imports

How to organize code, what to export, and how to write imports that survive across tsc, esbuild, SWC, bundlers, and
Node's native TS stripping.

## ESM is the default

For any new TypeScript project in 2026, the answer is ECMAScript modules. CJS is fine inside legacy code, but new files
use ESM unless they have to interoperate with a CJS-only consumer at the boundary.

Mark the package:

```json
{
    "type": "module"
}
```

Use `.ts` (which compiles to `.js`), `.mts` (always ESM), or `.cts` (always CJS) intentionally. Most code is `.ts`.

## Named exports over default exports

```ts
// ✅ Named
export function add(a: number, b: number): number {
    return a + b;
}
export function multiply(a: number, b: number): number {
    return a * b;
}

// ❌ Default
export default function add(a: number, b: number): number {
    return a + b;
}
```

Why:

- Renaming a named export updates every importer through a refactor. Renaming a default export updates nothing.
- Grep finds named exports across the codebase.
- Default exports allow each importer to spell the name differently, which makes call sites inconsistent.
- Most modules export more than one thing. The "one default + helpers" shape is an artificial restriction.

The exceptions where default exports are reasonable:

- A framework requires it (React `lazy()`, Next.js page modules, Vue SFCs).
- The module truly has exactly one obvious entrypoint and no peripheral exports.

## No static utility classes

```ts
// ❌ Ceremony
export default class MathUtil {
    static add(a: number, b: number): number {
        return a + b;
    }
}
// MathUtil.add(1, 2)

// ✅ The module is the namespace
export function add(a: number, b: number): number {
    return a + b;
}
// import { add } from "./math.js"; add(1, 2)
```

A class with only static methods is a worse module. Use the module.

`@typescript-eslint/no-extraneous-class` enforces this.

## No `namespace` in application code

`namespace` is a pre-modules holdover. Inside application code, use modules. The legitimate uses are narrow: ambient
declaration files that augment global types or model an existing global library.

## Type-only imports and exports

With `verbatimModuleSyntax` on, the source must say what is type-only. This makes elision behavior predictable across
every TypeScript toolchain.

```ts
// ✅
import type { User } from "./types.js";
import { greet, type Greeting } from "./greet.js";

export type { User };
export { greet };
```

`@typescript-eslint/consistent-type-imports` (with `{ prefer: "type-imports" }`) inserts these automatically.

Why this matters:

- File-by-file transpilers (esbuild, SWC, Node's native TS stripping) have no whole-program type information. They
  cannot know whether `User` is a runtime value or a type — the source must say so.
- With `verbatimModuleSyntax`, the emit is exactly what you wrote (modulo type-only stripping). Easier to reason about.
- Round-trips cleanly through declaration emit.

## File extensions on relative imports

Under `module: "nodenext"` and Node's native TS stripping, **include the `.js` extension on relative imports**, even
when importing a `.ts` file. The runtime resolves the `.js` path; tsc maps it to your `.ts` source.

```ts
// ✅
import { greet } from "./greet.js";
import type { User } from "../models/user.js";
```

If you write `./greet.ts` directly in source and emit JS, enable `rewriteRelativeImportExtensions` so the emit becomes
`./greet.js`.

Under bundler resolution (`moduleResolution: "bundler"`), the bundler decides — extensionless relative imports are
conventional, and the bundler resolves to whichever file exists.

## Package / subpath imports

For larger projects, use `imports` in `package.json` to avoid `../../../../`:

```json
{
    "imports": {
        "#shared/*": "./src/shared/*.js",
        "#test-helpers": "./test/helpers/index.js"
    }
}
```

```ts
import { Logger } from "#shared/logger.js";
import { fakeUser } from "#test-helpers";
```

This works under both Node and most bundlers, and survives moves better than path aliases configured only in
`tsconfig.paths`. Avoid `tsconfig.paths` as the only mechanism — at minimum mirror it in `package.json` or in the
bundler's resolver.

## Module resolution choices

| Mode       | When                                                                                                                                                                                                |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nodenext` | Code that runs in Node directly, libraries, declaration emit.                                                                                                                                       |
| `bundler`  | Code that always goes through a bundler before running (Vite, Rolldown, esbuild bundle, Rollup, webpack). Allows extensionless imports and resolves `package.json` `exports` like a modern bundler. |
| `node16`   | Same as `nodenext` but pinned to Node 16 semantics. Use only when explicitly required.                                                                                                              |
| `classic`  | Pre-Node-modules resolution. Never use this in new code.                                                                                                                                            |

## Library packaging

When publishing on npm:

```json
{
    "type": "module",
    "main": "./dist/index.js",
    "module": "./dist/index.js",
    "types": "./dist/index.d.ts",
    "exports": {
        ".": {
            "types": "./dist/index.d.ts",
            "import": "./dist/index.js"
        },
        "./package.json": "./package.json"
    },
    "sideEffects": false,
    "files": ["dist"]
}
```

- `"exports"` defines the public surface. Anything not listed cannot be imported by consumers (deep imports stop working
  when exports are set — that is the feature).
- `"sideEffects": false` tells bundlers tree-shaking is safe. Only set this if it is true. If a few files genuinely have
  side effects (CSS imports, polyfills), list them:

    ```json
    { "sideEffects": ["./dist/polyfill.js", "*.css"] }
    ```

- `"types"` (and `"types"` inside each `exports` entry) points consumers at your generated `.d.ts`.

If you need dual ESM + CJS output, prefer letting a build tool (e.g., `tsup`, `unbuild`) emit both, with a CJS `require`
entry inside `exports` — and verify on real consumers, since type-only `import type` from a CJS consumer has subtle
pitfalls.

## Ambient declarations — quarantine them

Use `declare module "..."` only to model values that genuinely live outside your source (a JS library without types, a
virtual module a bundler injects):

```ts
// legacy-lib.d.ts
declare module "legacy-lib" {
    export interface Config {
        retries: number;
    }
    export function createClient(config: Config): { connect(): Promise<void> };
}
```

Avoid global declarations unless the runtime symbol is truly global:

```ts
// ❌ Polluting the global namespace
declare const API_URL: string;
```

Prefer reading config from a real module:

```ts
// config.ts
export const API_URL = process.env.API_URL ?? throwError("API_URL not set");
```

When you must declare a real global (e.g., `window.__INITIAL_STATE__` injected by SSR), wrap the declaration in
`declare global { ... }` inside a module file, not a side-channel `.d.ts`.

## Tree-shaking-friendly module graphs

Tree shaking depends on **static** `import`/`export` structure. Patterns that defeat it:

- `require("./" + name)` — non-analyzable dynamic require.
- Direct call of the dynamic-code-execution function (the one that takes a string and runs it as JS) — esbuild and other
  bundlers warn that it disables dead code elimination in reachable scopes.
- Side-effect-heavy module top levels (mutating globals, registering things) — even if downstream importers do not use
  the exported symbols. Set `"sideEffects": false` only if it is true.

The good pattern for runtime branching is dynamic `import()`, which bundlers understand and can chunk:

```ts
export async function run(kind: "widget" | "gadget"): Promise<void> {
    if (kind === "widget") {
        const m = await import("./widget.js");
        return m.run();
    }
    const m = await import("./gadget.js");
    return m.run();
}
```

## Import sort order

Delegate import ordering to Prettier (`@trivago/prettier-plugin-sort-imports`) or ESLint (`eslint-plugin-import` /
`simple-import-sort`). It is not worth disagreeing about in review.
