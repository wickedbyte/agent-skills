---
name: best-practices-typescript
description: >-
    Use when writing, modifying, or reviewing TypeScript code (.ts, .tsx, .mts, .cts files) — including interfaces,
    types, generics, tsconfig, async patterns, error handling, Vue composables, or any file that emits to JavaScript.
    Applies to every TypeScript task. Triggers for strict-mode-first conventions, named interfaces over `any`/`object`,
    ESM with named exports, `readonly` by default, discriminated unions, `as const` over enums, `unknown` at trust
    boundaries, and type-only imports. Use this even when the user does not explicitly mention TypeScript style.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# How to Write TypeScript

This skill captures an opinionated, framework-agnostic TypeScript style that targets the language as it stands in
mid-2026 (TypeScript 6.x, ESLint 10 flat config, Vite 8 with Rolldown as the default bundler, mature native Node TS
stripping, typescript-eslint with `projectService`). Follow it for any TypeScript work.

## The One Idea

**TypeScript is JavaScript with a compile-time model, not a different runtime language.** Types are erased at runtime;
runtime behavior is JavaScript semantics + module loading + host environment. Good TypeScript therefore starts with good
JavaScript design — clear modules, explicit data shapes, small APIs, predictable error handling, runtime validation at
boundaries — and adds the type system on top for static feedback and tooling.

Two consequences drop out of that idea, and they shape everything below:

1. **Compile-time guarantees stop at runtime boundaries.** JSON, storage, env vars, URL params, DOM input,
   `postMessage`, plugin hooks — all of these still need to be validated, no matter how strict the types are.
2. **Type-system expressiveness has a real cost.** Anonymous mega-unions, deep intersections, and clever conditionals
   hurt the checker, the editor, and the next reader. Prefer named types, small interfaces, and simple relationships.

## When to Use This Skill

Use it for any of:

- Authoring or editing `.ts`, `.tsx`, `.mts`, `.cts` files
- Setting up or changing `tsconfig.json`, ESLint config, or build/CI scripts
- Designing API shapes (interfaces, generics, union types, public type contracts)
- Writing Vue composables, React components, Node services, CLIs, libraries
- Reviewing TypeScript for `any`, floating promises, weak nullability, or untyped boundaries
- Migrating JavaScript to TypeScript or tightening an existing TS codebase

Do not use it for: pure CSS/HTML changes that touch no TypeScript, or for non-TypeScript JS where the existing code is
intentionally untyped.

## Core Defaults — apply unless the task gives a specific reason not to

### 1. Strict-mode-first tsconfig

A baseline `tsconfig.json` for new projects:

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
        "sourceMap": true
    }
}
```

For bundled browser code, swap to `"module": "preserve"` (or `"esnext"`) with `"moduleResolution": "bundler"`. For
direct `.ts` execution under native Node TS stripping, add `"erasableSyntaxOnly": true`. See `references/tsconfig.md`
for the full flag rationale and per-target matrices.

### 2. ESM, named exports, free functions

- Use ECMAScript modules as the unit of organization. Modules already give you scope; you do not need wrapper classes.
- Prefer many small named exports over default exports. Default exports defeat grep, hurt rename refactors, and obscure
  the public surface.
- Top-level functions beat `class FooUtil { static bar() {} }`. A static-only utility class is ceremony around a module.
- Avoid namespaces in application code; they predate modules.

### 3. Names encode role and intent

| Kind                         | Convention                                                         |
| ---------------------------- | ------------------------------------------------------------------ |
| Types, interfaces, classes   | `PascalCase`                                                       |
| Values, functions, variables | `camelCase`                                                        |
| Functions                    | Verbs (`normalizeUserName`, `parsePort`)                           |
| Data                         | Nouns (`UserNameRecord`, `RequestContext`)                         |
| Booleans                     | Predicate-shaped (`isEnabled`, `hasParent`, `canEdit`)             |
| Interfaces                   | No `I` prefix, no `Interface` suffix — the keyword already says so |
| Files                        | Match the principal export when there is one                       |

Pick a name that survives the "six months later" test: would you know what this is without opening the file?

### 4. `interface` for object shapes, `type` for type operators

- Default to `interface` for object contracts and public record-like shapes. Interfaces flatten, display better, detect
  conflicts directly, and cache more cheaply in the checker than long intersections.
- Use `type` for unions, tuples, mapped/conditional types, primitive aliases, and aliases of non-object forms.
- Avoid gratuitous intersections (`A & B & C`) when a simple interface composition (
  `interface User extends Entity, Audited`) says the same thing.

```ts
interface User {
    id: string;
    email: string;
    active: boolean;
}

type UserId = User["id"];
type UserState = "active" | "disabled";
```

See `references/types-and-modeling.md` for generics, branded types, `satisfies`, discriminated unions, and value
objects.

### 5. Model nullability explicitly; distinguish "absent" from "present-but-empty"

- `field: string | null` — the field is always present but may have no value.
- `field?: string` — the field may be omitted entirely.
- Use `?.` and `??`, not `&&` and `||`, when the semantics are specifically nullish. `||` falls back on `""`, `0`, and
  `false`, which is almost never what an API contract means.
- Avoid `value!` (non-null assertion) except when you are very close to a proven invariant. If you find yourself
  reaching for `!`, narrow first or model the absence in the type.
- `useUnknownInCatchVariables` is on by default in your strict config — catch handlers receive `unknown` and must
  narrow.

### 6. `readonly` by default for data

Anything that represents a captured fact — value object, domain event, API payload, request context — gets `readonly` on
every property. Mutation requires explicit justification.

```ts
interface StackFrame {
    readonly file: string;
    readonly line: number;
    readonly function: string;
    readonly class: string | null;
    readonly type: "::" | "->" | null;
}

function withStatus(post: PostMetadata, status: PostStatus): PostMetadata {
    return { ...post, status };
}
```

Remember `readonly` is shallow: a `readonly tags: string[]` still lets callers mutate the array. Use
`readonly string[]` (or model nested immutability) when you mean it. For legitimate mutable state, use a class with
private fields and explicit mutation methods. See `references/immutability.md`.

### 7. Discriminated unions for state, exhaustive switches via `never`

When a value can be one of several states, encode each state explicitly with a shared discriminant. Make the switch
exhaustive with a `never` assignment in the default branch — the compiler will then refuse to let you add a new variant
without handling it.

```ts
type Shape =
    | { kind: "circle"; radius: number }
    | { kind: "rect"; width: number; height: number };

function area(shape: Shape): number {
    switch (shape.kind) {
        case "circle":
            return Math.PI * shape.radius ** 2;
        case "rect":
            return shape.width * shape.height;
        default: {
            const unreachable: never = shape;
            return unreachable;
        }
    }
}
```

### 8. `as const` objects + literal unions instead of `enum`

`enum` has surprising runtime behavior (especially numeric enums), does not tree-shake cleanly, and interacts poorly
with `isolatedModules`, native Node TS stripping, and mixed toolchains. `const enum` is even worse for shared code.
Prefer:

```ts
export const Status = {
    Pending: "pending",
    Done: "done",
} as const;

export type Status = (typeof Status)[keyof typeof Status];

export function isDone(status: Status): boolean {
    return status === Status.Done;
}
```

This gives you runtime values _and_ precise types, with none of the enum pitfalls. Use a real `enum` only when you
specifically need the runtime enum object (rare).

### 9. `unknown` at trust boundaries, narrow before use

Everything entering the program from outside the type system — `JSON.parse`, `fetch`, `localStorage`, env vars, CLI
args, `postMessage`, plugin hooks — is `unknown`. Validate, then narrow. Never use `any` for untrusted input.

```ts
type User = { name: string };

function isUser(x: unknown): x is User {
    return (
        typeof x === "object" &&
        x !== null &&
        typeof (x as Record<string, unknown>).name === "string"
    );
}

export function parseUser(json: string): User {
    const value: unknown = JSON.parse(json);
    if (!isUser(value)) throw new Error("Invalid user");
    return value;
}
```

For richer schemas, reach for a validation library (Zod, Valibot, ArkType, Effect Schema) — but the shape of the
discipline is the same: `unknown` in, validated domain type out.

### 10. Throw `Error`, catch `unknown`, prefer result objects for expected failures

- Throw `Error` or a subclass with a useful message. Never throw strings or bare objects — they have no stable
  interface.
- In `catch`, the variable is `unknown`. Narrow with `instanceof Error` before reading `.message`.
- For _expected_ domain failures (validation, parsing, lookups), prefer returning a discriminated `Result<T, E>` or
  `T | null` over throwing. Exceptions are for _unexpected_ conditions.
- Name exception classes after the problem (`InvalidPort`, `UnableToReadFile`), not the category (`MyException`,
  `ValidationError` without context).

### 11. Type-only imports/exports are explicit

With `verbatimModuleSyntax` on, the source must say what is type-only. This makes elision predictable across tsc,
esbuild, swc, native Node stripping, and bundlers.

```ts
import type { User } from "./types.js";

export type { User };

export function formatUser(user: User): string {
    return user.id;
}
```

ESLint's `@typescript-eslint/consistent-type-imports` enforces this automatically.

### 12. `const` by default; `var` never; `let` only for real reassignment

`const` does not deep-freeze the value — it only forbids reassigning the binding. Combine with `readonly` / `as const`
when you also want immutable contents.

### 13. Async: `async`/`await` for linear flow, never float a promise

- Prefer `async`/`await` over long `.then()` chains for ordinary application code.
- Inside `try`/`catch`, `await` the promise you want to catch — `return promise` from inside a `try` does not run the
  `catch`. The rule `@typescript-eslint/return-await: ["error", "in-try-catch"]` catches this.
- Every promise is awaited, returned, attached with `.catch()`, or explicitly discarded with `void`. Floating promises
  eat rejections and break causality. `@typescript-eslint/no-floating-promises` enforces this.
- Use `Promise.all` (or a concurrency limiter for large fan-out) for independent work. Serial `await` composes latencies
  instead of overlapping them.

### 14. Generate `.d.ts` from source; ambient declarations are quarantined

If you own the source, generate `.d.ts` from it (`declaration: true`, optionally `emitDeclarationOnly` in a separate
types lane). Handwritten `.d.ts` for your own code drifts silently. Use ambient `declare module "..."` only to describe
values that genuinely live outside your source. Avoid global declarations unless the runtime symbol is truly global.

### 15. Domain modeling — every concept gets a name

If a concept has a name in the domain and carries more than one piece of state, it deserves a named interface (or class,
when it has behavior). The smell is **passing the same anonymous shape to more than one function**, or **a function that
returns an array/object and the caller has to know its keys**. Branded primitive wrappers (
`type PostSlug = string & { readonly __brand: "PostSlug" }`) prevent accidental string-swapping at the type level. See
`references/types-and-modeling.md`.

## Quick Triage Table

When the task is unclear, use this to pick the canonical default:

| Situation                                     | Default choice                                                         |
| --------------------------------------------- | ---------------------------------------------------------------------- |
| Modeling an object record / API payload       | `interface` with `readonly` properties                                 |
| Modeling alternatives / states                | Discriminated `type` union                                             |
| Modeling a fixed set of values                | `as const` object + derived `(typeof X)[keyof typeof X]` union         |
| Modeling a primitive wrapper with no behavior | Branded type                                                           |
| Modeling a primitive wrapper with behavior    | `readonly` class                                                       |
| External input                                | `unknown`, narrowed via type guard or schema                           |
| Caught exception                              | `unknown`, `instanceof Error` to narrow                                |
| Optional field in API response                | `field: T \| null` (present-but-empty)                                 |
| Field that may not be sent at all             | `field?: T` (absent)                                                   |
| Default for a nullish value                   | `??` (not `\|\|`)                                                      |
| Conditional access through a chain            | `?.` (not `&&`)                                                        |
| Concurrent independent async work             | `Promise.all` (or a limiter)                                           |
| One-of-many constants for UI                  | `as const` object + literal union — not `enum`                         |
| Sharing structure across object variants      | `interface Base { ... }; interface Variant extends Base { kind: "x" }` |
| Public type validation in tests               | `tsd` or `// @ts-expect-error` (never `// @ts-ignore`)                 |

## Reference Files

Read the relevant file when the SKILL.md guidance leaves a judgment call open:

- `references/tsconfig.md` — Recommended config, flag-by-flag rationale, per-target matrices (Node, bundler, library,
  direct `.ts` execution), declaration emit, project references, migration sequence.
- `references/types-and-modeling.md` — Interfaces vs types in depth, generics that preserve information, `satisfies`,
  branded types, value objects (interface vs class), discriminated unions, exhaustiveness, utility types (`Pick`,
  `Partial`, `Readonly`), overloads.
- `references/modules-and-imports.md` — ESM patterns, named vs default exports, type-only imports/exports,
  `verbatimModuleSyntax`, file extensions, module resolution for Node vs bundlers, declaration emit, ambient modules.
- `references/nullability-and-errors.md` — `null` vs `undefined` philosophy, optional chaining, `??`, non-null assertion
  rules, error class design, `unknown` in catch, result-object patterns for expected failures.
- `references/immutability.md` — `readonly` semantics (shallow!), `Readonly<T>`, `readonly T[]`, wither pattern,
  mutable-state classes with private fields, mixed mutability (e.g., stoppable events).
- `references/async-patterns.md` — `async`/`await`, awaiting in `try`/`catch`, no floating promises, `Promise.all`/
  `allSettled`/`any`, concurrency limiters, AbortSignal, generators/iterables, streams.
- `references/vue-composables.md` — Composable naming (`use<Domain>`), small returned surface, `as const` returns,
  imperative method verbs, `init` for side effects on mount, SSR safety.
- `references/performance.md` — V8 hidden classes / object shapes, dense vs holey arrays, typed arrays for numeric
  workloads, allocation discipline on hot paths, when to use `Map`/`Set`, worker offloading, streaming I/O.
- `references/testing-linting-build.md` — ESLint 10 flat config with typescript-eslint and `projectService`, Prettier
  scope, type tests (`tsd`, `@ts-expect-error`), Node built-in test runner, separating transpile / typecheck /
  declaration-emit lanes, when to use esbuild/SWC/Vite/Rollup/webpack.

## Common Mistakes (and the fix)

| Mistake                                                                 | Fix                                                                                      |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `function f(x: any)` for "I'll figure it out later"                     | `unknown` + a narrowing guard or schema                                                  |
| `const x = JSON.parse(s) as MyType` at a boundary                       | `JSON.parse` is `unknown`; validate, then assign                                         |
| `xs.find(...)!` after a loop                                            | Hoist the narrowing into a guard; if the invariant is real, comment why `!` is justified |
| `enum Status { Pending, Done }` in shared code                          | `const Status = { Pending: "pending", Done: "done" } as const` + derived union           |
| `type User = { id: string } & { email: string }`                        | One `interface User { id: string; email: string }`                                       |
| `export default class Util { static foo() {} }`                         | Module-level `export function foo() {}`                                                  |
| `import { User } from "./types.js"` (type-only)                         | `import type { User } from "./types.js"`                                                 |
| `for (const i in xs) total += xs[i]`                                    | `for (const x of xs) total += x` (`for...in` walks keys, not values)                     |
| `try { return p.then(...) } catch {}`                                   | `await` the promise inside the `try`                                                     |
| `someAsync()` on its own line                                           | `void someAsync().catch(handle)` or `await`                                              |
| `if (value)` for nullish check                                          | `if (value != null)` or use `?.` / `??` for the operation itself                         |
| Returning a fresh accumulator object every `.reduce` step on a hot path | Single-pass loop with `let`s and one returned object                                     |

## Migration Order for an Existing Codebase

If a project is not yet strict, layer it on. Do not flip every flag at once:

1. Add CI scripts: `typecheck` (`tsc --noEmit`), `lint`, `format:check`, `test`.
2. Turn on `strict: true`. Fix the obvious implicit-`any`/nullability/unsafe-index issues.
3. Enable `noUncheckedIndexedAccess`, `useUnknownInCatchVariables`.
4. Enable `exactOptionalPropertyTypes`, `noImplicitOverride`.
5. Convert imports/exports to ESM and add `import type` where appropriate. Turn on `verbatimModuleSyntax` and
   `isolatedModules`.
6. Replace `const enum`s and public `enum`s with `as const` objects, replace static utility classes with module-level
   functions, and remove handwritten public `.d.ts` in favor of generated declarations.
7. Add `tsd` / `@ts-expect-error` type tests for public APIs.
8. Pay down `// @ts-expect-error` / `// @ts-nocheck` over time; the right metric is "fewer suppressions every quarter",
   not "permanent carve-outs".

`// @ts-expect-error` is preferred over `// @ts-ignore` because it fails the build when the underlying error
disappears — it stays honest. Use `// @ts-nocheck` only as a quarantine on a specific hard file, with a tracking note.

## Pre-Commit Self-Check

Before saying "done" on a TypeScript change, verify:

- [ ] No `any`. If `unknown` would not work, document why.
- [ ] Every function that takes or returns domain data uses a **named interface**, not `any`, `object`, or an anonymous
      shape.
- [ ] `null` vs `?` is intentional — present-but-empty vs absent.
- [ ] Value-object-like interfaces have `readonly` on every property.
- [ ] No floating promises. Every async call is awaited, returned, `.catch()`ed, or `void`-discarded.
- [ ] Caught errors are typed `unknown` and narrowed with `instanceof Error`.
- [ ] Imports that are only used as types use `import type`.
- [ ] Discriminated unions have an exhaustive `switch` with `never` in the default branch.
- [ ] No `enum` (use `as const` + literal union) unless a real runtime enum object is required.
- [ ] If the file is a Vue composable: name starts with `use`, returns `as const`, method names are imperative verbs,
      `init()` is explicit (not eagerly invoked).
- [ ] `tsc --noEmit` is clean. `eslint` is clean.
