# tsconfig and Compiler Flags

The compiler config is a semantic choice, not build trivia. The flags below align types with runtime truth, match the
configured runtime, and keep the checker honest.

## Baseline recommendation

```json
{
    "compilerOptions": {
        "target": "ES2022",
        "module": "nodenext",
        "moduleResolution": "nodenext",
        "strict": true,
        "noUncheckedIndexedAccess": true,
        "exactOptionalPropertyTypes": true,
        "useUnknownInCatchVariables": true,
        "noImplicitOverride": true,
        "isolatedModules": true,
        "verbatimModuleSyntax": true,
        "declaration": true,
        "sourceMap": true,
        "skipLibCheck": false
    },
    "include": ["src/**/*"],
    "exclude": ["dist", "coverage", "generated"]
}
```

Adjust `module`/`moduleResolution` based on the actual runtime; see the matrix below. Everything else should stay on
unless you have a documented reason.

## Strictness flags — what each one actually catches

| Flag                                   | Catches                                                                                | Why it earns its keep                                                  |
| -------------------------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `strict`                               | Implicit `any`, missing null checks, function contravariance bugs, unused `this`, etc. | The umbrella for the standard `strict*` family. Always on.             |
| `noUncheckedIndexedAccess`             | `arr[i]` and `record[key]` types include `\| undefined`                                | Index access is not safe at runtime; the type should say so.           |
| `exactOptionalPropertyTypes`           | Treats `{ x?: T }` as "may be omitted" rather than "may be `undefined`"                | Forces you to choose `T \| undefined` vs `T?` deliberately.            |
| `useUnknownInCatchVariables`           | `catch (err)` is `unknown` instead of `any`                                            | Forces narrowing before reading `.message`.                            |
| `noImplicitOverride`                   | Subclass method override must say `override`                                           | Prevents silent drift when a base class renames a method.              |
| `noFallthroughCasesInSwitch`           | `case A:` without `break`/`return`/`throw`                                             | Cheap to enable, catches a classic bug.                                |
| `noUnusedLocals`, `noUnusedParameters` | Dead bindings, dead args                                                               | Prefer enabling in CI rather than the editor — `_`-prefix to suppress. |

## Module / target matrix

| Target                                                               | `module`                 | `moduleResolution` | Notes                                                                                                           |
| -------------------------------------------------------------------- | ------------------------ | ------------------ | --------------------------------------------------------------------------------------------------------------- |
| Node app or service                                                  | `nodenext`               | `nodenext`         | Write import specifiers that make sense at runtime; include `.js` on relative imports.                          |
| Browser app with bundler (Vite/Rolldown, esbuild, Rollup, webpack)   | `preserve` (or `esnext`) | `bundler`          | Let the bundler own extensionless and bare imports.                                                             |
| Library shipped on npm                                               | `nodenext`               | `nodenext`         | Safest for declaration consumers. Emit ESM + (optionally) CJS via build tooling, and publish proper `exports`.  |
| Direct `.ts` execution under Node's native TS stripping (Node 22.6+) | runtime-specific         | runtime-specific   | Add `"erasableSyntaxOnly": true`. Avoid runtime-only TS constructs (`enum`, `namespace`, parameter properties). |
| Cross-format `.ts`/`.mts`/`.cts` sources with `.js`-only emit        | nodenext                 | nodenext           | Use `"rewriteRelativeImportExtensions": true` so `./foo.ts` becomes `./foo.js` on emit.                         |

### Targets

- Pick the lowest target your deployment actually requires. Older targets emit more downlevel helper code and can be
  measurably slower.
- For Node 22 LTS / Node 24, `ES2022` is a safe modern default; `ES2023` is fine if your deps allow it.
- Browsers: align with your supported browserslist. Modern app targets in mid-2026 typically allow `ES2022` or `ES2023`.
- `target: "ES5"` is deprecated in TypeScript 6.0 and is scheduled for removal in 7.0. If you must keep it temporarily,
  set `"ignoreDeprecations": "6.0"` and plan the upgrade.

## Declaration emit

```json
{
    "compilerOptions": {
        "declaration": true,
        "declarationMap": true,
        "emitDeclarationOnly": false
    }
}
```

- `declaration: true` — generate `.d.ts` from source. **Never handwrite `.d.ts` for your own code.**
- `declarationMap: true` — editors can jump from `.d.ts` to original source.
- For libraries, a common pattern is a separate `tsconfig.types.json` with `emitDeclarationOnly: true`, while a fast
  transpiler (esbuild/SWC) handles JS emit.

If you need to ship a stable, lazily-checked public type contract, `"isolatedDeclarations": true` makes the checker
require explicit annotations on exports so declarations can be emitted file-by-file without whole-program inference.
Useful for monorepo type lanes.

## Project references and incremental

For non-trivial codebases or monorepos:

```json
{
    "compilerOptions": {
        "incremental": true,
        "composite": true,
        "tsBuildInfoFile": "./node_modules/.cache/tsc/app.tsbuildinfo"
    },
    "references": [{ "path": "../shared" }],
    "include": ["src/**/*"],
    "exclude": ["dist", "coverage", "generated"]
}
```

- `incremental` persists graph information in `.tsbuildinfo` and dramatically speeds up subsequent type checks.
- `composite` is required on referenced projects and turns on `declaration`, `emitDeclarationOnly` semantics for
  downstream consumers.
- Resist `"include": ["**/*"]`. Narrow includes shrink the project graph and shave seconds off every type check.

## Sourcemaps

```json
{
    "compilerOptions": {
        "sourceMap": true,
        "declarationMap": true
    }
}
```

- Prefer external sourcemaps in development. Inline sourcemaps (`inlineSourceMap`, `inlineSources`) inflate output and
  are usually wrong for shipping.
- In Node, run with `node --enable-source-maps dist/index.js` for usable stack traces. Be aware this adds latency to
  every `Error.stack` access; turn it off in benchmarks.

## Escape hatches and what they actually cost

| Flag                  | What it does                                                         | When to use it                                                                            | What it costs                                       |
| --------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `skipLibCheck`        | Skip type checking inside `node_modules/**/*.d.ts`                   | Default off in libraries; on is sometimes pragmatic in apps when a dep ships broken types | Hides real bugs in your dependency type surface.    |
| `--noCheck`           | Disables full type checking for an emit pass                         | A separate fast-emit lane in CI; never the only check                                     | If it is the only gate, the codebase rots silently. |
| `// @ts-expect-error` | Suppresses one error on the next line; fails if the error disappears | Targeted, temporary, reviewable suppressions; negative type tests                         | None — it self-heals.                               |
| `// @ts-ignore`       | Suppresses one error on the next line forever                        | Almost never. `@ts-expect-error` is strictly better.                                      | Rots silently.                                      |
| `// @ts-nocheck`      | Disables checking for the entire file                                | Quarantine on one stubborn legacy file                                                    | Hides every bug in that file. Track every instance. |

## CI lanes

Separate the cost models:

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

For a library:

```json
{
    "scripts": {
        "build": "esbuild src/index.ts --bundle --platform=node --outdir=dist",
        "build:types": "tsc -p tsconfig.types.json --emitDeclarationOnly",
        "typecheck": "tsc --noEmit",
        "test": "node --test",
        "lint": "eslint .",
        "format:check": "prettier --check ."
    }
}
```

Why split: `tsc` is the authoritative checker but is not the fastest transpiler. esbuild/SWC are very fast file-by-file
transpilers but cannot do whole-program type checking. Vite 8 (with Rolldown as the default bundler since the March 2026
stable release) explicitly delegates type checking to a separate `tsc` lane. Match the docs.

## Migration order

If a project is not yet strict, layer it on:

1. Add CI lanes for `typecheck`, `lint`, `format:check`, `test`.
2. Turn on `strict`. Fix obvious implicit-`any` / nullability / unsafe-index issues.
3. Add `noUncheckedIndexedAccess` and `useUnknownInCatchVariables`.
4. Add `exactOptionalPropertyTypes` and `noImplicitOverride`.
5. Convert imports/exports to ESM. Add `import type` everywhere it applies.
6. Turn on `verbatimModuleSyntax` and `isolatedModules` (fix the resulting issues — usually `const enum`s and
   runtime-typed imports).
7. Replace public `enum`s and static utility classes; switch handwritten public `.d.ts` to generated declarations.
8. Add type-level tests (`tsd`) for public APIs.
9. Pay down `// @ts-expect-error` / `// @ts-nocheck` quarterly.

Use two configs during long migrations:

```json
// tsconfig.base.json
{ "compilerOptions": { "strict": true } }
```

```json
// tsconfig.strict.json
{
    "extends": "./tsconfig.base.json",
    "compilerOptions": {
        "noUncheckedIndexedAccess": true,
        "exactOptionalPropertyTypes": true,
        "useUnknownInCatchVariables": true,
        "noImplicitOverride": true
    }
}
```

Run `tsc --noEmit -p tsconfig.strict.json` in CI while production builds continue under the base config until the strict
backlog is burned down.

## Diagnostics when builds get slow

- `tsc --extendedDiagnostics` for a quick summary (files, types, instantiations, memory).
- `tsc --generateTrace ./trace` for a chrome://tracing-loadable timeline.
- `tsc --generateCpuProfile ./tsc.cpuprofile` for a V8 CPU profile of the checker itself.
- `tsc --explainFiles` and `--traceResolution` when the project graph mysteriously grows.

These exist for the "why did TypeScript just get slow?" class of incident. Use them before guessing.
