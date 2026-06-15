# Performance

How to write TypeScript that compiles fast and runs fast. Two separate planes — keep them separate.

## Two performance planes

1. **Runtime performance** — JavaScript on V8 (or another engine) rewards stable object shapes, dense homogeneous
   arrays, predictable control flow, the right data structure for the operation, bounded allocation, and intentional
   async/concurrency.
2. **Compile / tooling performance** — the TypeScript checker, emitter, bundler, and linter reward smaller project
   graphs, named (cacheable) types, project references, incremental builds, and separation of fast transpilation from
   authoritative type checking.

Optimize the right plane. A type-system tweak does not make a slow loop faster; a packed-array trick does not make `tsc`
faster.

## Runtime — measure first

Before changing any code "for performance":

```ts
import { performance } from "node:perf_hooks";
import process from "node:process";

export function bench(name: string, fn: () => unknown, iters = 50_000) {
    // warm-up — V8 starts in cheaper tiers and optimizes after observing behavior
    for (let i = 0; i < 10_000; i++) fn();

    const startHeap = process.memoryUsage().heapUsed;
    const t0 = performance.now();
    for (let i = 0; i < iters; i++) fn();
    const t1 = performance.now();
    const endHeap = process.memoryUsage().heapUsed;

    return {
        name,
        nsPerOp: ((t1 - t0) * 1e6) / iters,
        heapDeltaBytes: endHeap - startHeap,
    };
}
```

In the browser, the same shape works with `performance.now()` and the DevTools Performance panel. For real diagnosis,
use CPU profiles, heap snapshots, allocation profiles, and flame graphs — guesswork loses to data.

Collect at minimum: cold latency, warm latency or ns/op, p50/p95/p99 (not just average), heap delta. If the change does
not survive re-measurement, revert it — code clarity wins ties.

## Keep object shapes stable

V8 optimizes objects with the same properties in the same order. Adding properties conditionally or deleting them forces
shape transitions ("hidden class" churn) that defeat inline caches.

```ts
// ❌ Shape varies and properties get deleted
type Point = { x?: number; y?: number; z?: number };
export function makePoint(x: number, y: number, addZ: boolean): Point {
    const p: Point = {};
    p.x = x;
    if (Math.random() > 0.5) p.y = y;
    if (addZ) p.z = 0;
    delete p.y;
    return p;
}

// ✅ Initialize the full shape once with sentinel values
interface Point {
    readonly x: number;
    readonly y: number | null;
    readonly z: number | null;
}
export function makePoint(x: number, y: number, addZ: boolean): Point {
    return { x, y, z: addZ ? 0 : null };
}
```

Practical rules:

- Construct objects with all properties in a consistent order across the codebase.
- Use `null` or another sentinel instead of leaving properties off.
- Avoid `delete` on hot objects — it transitions the object to dictionary mode.
- Make hot path objects look like one shape, not many.

## Keep arrays dense and homogeneous

V8 tracks "element kinds" — `PACKED_SMI_ELEMENTS`, `PACKED_DOUBLE_ELEMENTS`, `PACKED_ELEMENTS`, then `HOLEY_*` variants
for arrays with holes. Holey and mixed-kind arrays are slower.

```ts
// ❌ Creates a hole and mixes kinds
const xs = [1, 2, 3];
xs[10] = 4; // hole
xs.push(NaN); // changes element kind
```

For dense numeric workloads, typed arrays are usually the right choice:

```ts
const xs = new Float64Array([1, 2, 3, 4]);
let sum = 0;
for (let i = 0; i < xs.length; i++) sum += xs[i];
```

Practical rules:

- Build arrays with `Array.from`, `[]` + `push`, or known-length allocation. Avoid sparse indexes.
- Do not push `NaN`/`undefined` into an array of numbers if you can use a typed array.
- Watch out for off-by-one loops that read past `length` — V8 deoptimizes the function.

## Pick the right data structure

| Operation                                | Right structure                                                               |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| Lookup by key                            | `Map` (dynamic keys, any type) or fixed-shape object (small static keys)      |
| Membership test                          | `Set`                                                                         |
| Ordered sequence                         | `Array`, accessed sequentially                                                |
| Repeated key/value access in inner loops | `Map` indexed once outside the loop, not `arr.find` inside                    |
| Dense numeric / binary data              | `Float64Array`, `Uint8Array`, etc.                                            |
| Frequent prepends                        | `Array` is O(n) for `unshift` — consider a linked structure or push + reverse |

```ts
// ❌ O(ids × users) — linear scan for every lookup
function findUsersSlow(users: readonly User[], ids: readonly string[]): User[] {
    return ids
        .map((id) => users.find((u) => u.id === id))
        .filter(Boolean) as User[];
}

// ✅ One O(users) indexing pass + O(ids) lookups
function findUsersFast(users: readonly User[], ids: readonly string[]): User[] {
    const byId = new Map(users.map((u) => [u.id, u] as const));
    const out: User[] = [];
    for (const id of ids) {
        const user = byId.get(id);
        if (user !== undefined) out.push(user);
    }
    return out;
}
```

## Minimize allocations on measured hot paths

Functional chains (`.filter(...).map(...).reduce(...)`) allocate intermediate arrays and per-element wrappers. That is
fine in almost all code. On a measured hot path, switch to a single pass.

```ts
// Fine in normal code; expensive on hot paths
export function summarize(xs: readonly number[]) {
    return xs
        .filter((x) => x > 0)
        .map((x) => ({ value: x * 2 }))
        .reduce(
            (acc, cur) => ({ count: acc.count + 1, sum: acc.sum + cur.value }),
            { count: 0, sum: 0 },
        );
}

// Cheap — one pass, two scalars, one allocated result
export function summarize(xs: readonly number[]) {
    let count = 0;
    let sum = 0;
    for (let i = 0; i < xs.length; i++) {
        const x = xs[i];
        if (x > 0) {
            count++;
            sum += x * 2;
        }
    }
    return { count, sum };
}
```

The rule is **not** "never use higher-order array methods" — it is "do not allocate per element inside a hot loop".
Profile first.

## Reuse buffers when streaming binary

For Node streams, file IO, and parsers, reuse `Buffer` / `Uint8Array` instances where possible. Each `Buffer.alloc(n)`
is a heap allocation; reading into a pre-sized buffer (`fd.read(buf, ...)`) is not.

## Concurrency on hot paths

- Use `Promise.all` for independent I/O. Serial `await` composes latency.
- Use a concurrency limiter (`p-limit`, semaphore) for large fan-out. 10,000 concurrent fetches hurt the backend, the
  OS, and you.
- For CPU-bound work, offload to a worker (Node `worker_threads` or Web Worker). The event loop is shared.
- Use `AbortSignal` to cancel work that no longer matters. Timeouts via `AbortSignal.timeout(ms)`.

## Stream rather than materialize for large I/O

For large files and long responses, stream:

```ts
import fs from "node:fs";
import { pipeline } from "node:stream/promises";

await pipeline(fs.createReadStream(src), fs.createWriteStream(dst));
```

`pipeline` handles backpressure and cleanup. Materializing into one giant `Buffer` blows up at large sizes.

## Compiler / tooling performance

### Prefer interfaces and `extends` over deep intersections

Intersection-of-many produces an anonymous "X & Y & Z" type that the checker re-relates everywhere. A single flat
`interface` is cheaper to compare and prints better in errors.

```ts
// ❌ Many intersections
type User = HasId & Named & Audited & { active: boolean };

// ✅ Interface inheritance
interface User extends AuditedEntity {
    active: boolean;
}
```

### Name expensive conditional and mapped types

A complex conditional type used in many places is re-evaluated each time inline. Naming it lets the checker cache the
relationship.

```ts
// ❌ Inlined
interface Box<T> {
    get<U>(x: U): U extends string ? { s: U } : { v: U };
}

// ✅ Named once
type GetResult<U> = U extends string ? { s: U } : { v: U };
interface Box<T> {
    get<U>(x: U): GetResult<U>;
}
```

### Avoid giant anonymous unions

```ts
// ❌ One enormous anonymous discriminated union
type Event = { kind: "a"; ... } | { kind: "b"; ... } | { kind: "c"; ... } | { ... }

// ✅ Factor shared structure and name members
interface BaseEvent { at: number; requestId: string }
interface AEvent extends BaseEvent { kind: "a" }
interface BEvent extends BaseEvent { kind: "b" }
type Event = AEvent | BEvent | /* ... */;
```

### Narrow the project graph

- Use explicit `include` paths. `"include": ["**/*"]` drags in too much.
- Split monorepos into project references with `composite: true` + `incremental: true`.
- For very large workspaces, `disableReferencedProjectLoad` and `disableSolutionSearching` can keep the editor
  responsive.

### Split build lanes

- Transpile with esbuild or SWC for fast feedback.
- Type-check with `tsc --noEmit` in a separate CI lane.
- Emit declarations with `tsc -p tsconfig.types.json --emitDeclarationOnly`.

Modern Vite (8.x) with Rolldown as the default bundler since the March 2026 stable release makes the same architectural
point: type checking is external to the dev server transform pipeline.

### Diagnostics when build time regresses

- `tsc --extendedDiagnostics` — quick numbers (files, types, instantiations, memory).
- `tsc --generateTrace ./trace` — chrome://tracing timeline.
- `tsc --generateCpuProfile` — V8 CPU profile of the checker.
- `tsc --explainFiles`, `--traceResolution` — what made the graph grow.

## What not to micro-optimize

The biggest wins in real codebases are:

1. The wrong algorithm (`O(n²)` where `O(n)` works).
2. The wrong data structure (linear scan where a `Map` works).
3. Doing I/O in a loop instead of batching/parallelizing.
4. Allocating per-element on a hot loop.

Below that, every micro-tweak is at most a few percent and easily regresses. **Profile, fix the bottleneck, re-measure,
keep the change only if the improvement is material.** Otherwise revert for clarity.
