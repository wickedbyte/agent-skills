# Async Patterns

`async`/`await`, concurrency, cancellation, streams, workers.

## `async`/`await` for linear flow

Prefer `async`/`await` over long `.then()` chains for ordinary application code. It reads top-to-bottom, narrows
naturally with `try`/`catch`, and reports errors with usable stack traces.

```ts
async function loadUser(id: string): Promise<User> {
    const response = await fetch(`/api/users/${id}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const raw: unknown = await response.json();
    return parseUser(raw);
}
```

## `return await` inside `try`/`catch`

If you want the `catch` to fire when the promise rejects, you must `await` the promise inside the `try` —
`return promise` from inside a `try` does not.

```ts
// ❌ The catch does not catch the rejection
async function loadValue(): Promise<string> {
    try {
        return Promise.resolve("ok").then((v) => v.toUpperCase());
    } catch {
        return "fallback";
    }
}

// ✅ await inside try
async function loadValue(): Promise<string> {
    try {
        const value = await Promise.resolve("ok");
        return value.toUpperCase();
    } catch {
        return "fallback";
    }
}
```

The lint rule is `@typescript-eslint/return-await: ["error", "in-try-catch"]`. Outside of try/catch, `return await` is
usually unnecessary noise.

## No floating promises

Every promise is awaited, returned, attached with `.catch()`, or explicitly discarded with `void` plus reasoning. A
floating promise eats its rejection — the program continues, and the error vanishes.

```ts
// ❌ Rejection is silently lost
async function saveAudit(): Promise<void> {
    throw new Error("disk full");
}
saveAudit();
console.log("request continues");

// ✅ Intentionally fire-and-forget — explicit
void saveAudit().catch((err) => {
    console.error(err);
});
console.log("request continues");

// ✅ Or actually wait
await saveAudit();
console.log("request continues");
```

Enforce with `@typescript-eslint/no-floating-promises: "error"`. The rule also catches callbacks that return promises in
spots that expect `void` (`forEach`, event handlers); fix those with `@typescript-eslint/no-misused-promises`.

## Concurrency: `Promise.all` for independent work

Serial `await` composes latency. When the operations are independent, run them concurrently.

```ts
// ❌ Serial — total latency is N × per-request latency
async function loadAll(ids: number[]): Promise<Item[]> {
    const out: Item[] = [];
    for (const id of ids) {
        out.push(await fetchItem(id));
    }
    return out;
}

// ✅ Parallel — total latency is max(per-request latency)
async function loadAll(ids: number[]): Promise<Item[]> {
    return Promise.all(ids.map(fetchItem));
}
```

Pick the variant that matches the failure semantics you want:

| Helper               | If one rejects                                                               | Use when                                     |
| -------------------- | ---------------------------------------------------------------------------- | -------------------------------------------- |
| `Promise.all`        | The whole thing rejects, others keep running but their results are discarded | All-or-nothing operations                    |
| `Promise.allSettled` | Returns `{ status: "fulfilled" \| "rejected", ... }` for each                | You want every result regardless of failures |
| `Promise.any`        | Resolves with the first fulfilled, only rejects when all reject              | "First successful response wins"             |
| `Promise.race`       | Settles with whichever finishes first, success or failure                    | Timeouts, first-to-respond                   |

## Concurrency limits — do not flood the backend

`Promise.all(ids.map(fetchItem))` with 10,000 ids will open 10,000 sockets. Limit fan-out with a semaphore or a small
library (`p-limit`, `p-map`):

```ts
import pLimit from "p-limit";

const limit = pLimit(10);
const items = await Promise.all(ids.map((id) => limit(() => fetchItem(id))));
```

Pick the limit based on the downstream's actual capacity (your DB pool, the upstream rate limit, browser
concurrent-connection budget). 5–20 is a reasonable default for HTTP fan-out.

## Cancellation with `AbortSignal`

Wire `AbortSignal` through every async API that could outlast its caller's interest. `fetch`, `setTimeout`-based delays,
and most modern Node APIs accept it.

```ts
async function loadWithTimeout<T>(
    url: string,
    parse: (input: unknown) => T,
    ms: number,
): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), ms);
    try {
        const response = await fetch(url, { signal: controller.signal });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const raw: unknown = await response.json();
        return parse(raw);
    } finally {
        clearTimeout(timer);
    }
}
```

For functions that should respect a caller-provided signal, accept `signal?: AbortSignal` and forward it. Use
`AbortSignal.timeout(ms)` and `AbortSignal.any([a, b])` to compose signals.

## CPU-bound work — offload to workers

The event loop is shared with every other request and UI frame. Heavy CPU work blocks it.

In Node, use `worker_threads`:

```ts
// main.ts
import { Worker } from "node:worker_threads";

export function hashInWorker(input: Uint8Array): Promise<Uint8Array> {
    return new Promise((resolve, reject) => {
        const worker = new Worker(new URL("./worker.js", import.meta.url), {
            workerData: input.buffer,
            transferList: [input.buffer],
        });
        worker.once("message", (buffer: ArrayBuffer) =>
            resolve(new Uint8Array(buffer)),
        );
        worker.once("error", reject);
    });
}
```

Transfer `ArrayBuffer` ownership with `transferList` to avoid copying. Use `SharedArrayBuffer` when you really need
shared memory and the security headers are in place.

In the browser, use Web Workers for the same reason — keep the UI responsive.

Workers are for **CPU-bound** work. They do not speed up I/O — Node's async I/O on the main thread already overlaps
requests.

## Streaming I/O for large payloads

For payloads that do not fit comfortably in memory (large files, long responses, log feeds), stream them.

```ts
// ❌ Materializes everything
import { readFile } from "node:fs/promises";
export async function loadHugeFile(path: string): Promise<string> {
    return readFile(path, "utf8");
}

// ✅ Streams with backpressure
import fs from "node:fs";
import { pipeline } from "node:stream/promises";
export async function copyHugeFile(src: string, dst: string): Promise<void> {
    await pipeline(fs.createReadStream(src), fs.createWriteStream(dst));
}
```

`stream/promises#pipeline` handles backpressure and cleanup correctly. For web environments, Web Streams (
`ReadableStream`, `WritableStream`, `TransformStream`) give the same primitives — `fetch` responses are already
`ReadableStream<Uint8Array>`.

## Iterables and async iterables

For sequences, iterables let you decouple production from consumption:

```ts
async function* paginate<T>(
    url: string,
    parse: (raw: unknown) => readonly T[],
): AsyncIterable<T> {
    let next: string | null = url;
    while (next !== null) {
        const response = await fetch(next);
        const body: unknown = await response.json();
        const parsed = body as { items: unknown; next: string | null };
        for (const item of parse(parsed.items)) yield item;
        next = parsed.next;
    }
}

for await (const post of paginate("/api/posts", parsePosts)) {
    await handle(post);
}
```

This holds at most one page in memory at a time and lets the consumer apply backpressure naturally.

## Common mistakes

| Mistake                                                         | Fix                                                             |
| --------------------------------------------------------------- | --------------------------------------------------------------- |
| Serial `await` in a loop over independent items                 | `Promise.all` (with a limit if needed)                          |
| `array.forEach(async ...)` (ignored promises)                   | `for...of` with `await`, or `Promise.all(array.map(async ...))` |
| `try { return p.then(...) } catch {}`                           | `try { return await p; } catch {}`                              |
| Calling `async` function without `await` / `.catch` / `void`    | One of the three                                                |
| No timeout / `AbortSignal` on outbound calls                    | Pass `AbortSignal.timeout(ms)` or thread a controller through   |
| Running CPU-heavy hashing/encoding/transform on the main thread | Worker thread (Node) or Web Worker (browser)                    |
| Reading a multi-GB file via `readFile`                          | Use `createReadStream` / `pipeline`                             |
