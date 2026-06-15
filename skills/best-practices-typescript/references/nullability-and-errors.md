# Nullability and Errors

`null`, `undefined`, optional chaining, error throwing, error catching, and when to return a result object instead.

## `null` vs `undefined` — pick deliberately

| Convention                     | Meaning                                                                           |
| ------------------------------ | --------------------------------------------------------------------------------- |
| `field: T \| null`             | Always present, may carry no value. The wire format includes the key with `null`. |
| `field?: T`                    | May be omitted entirely. The wire format may not include the key.                 |
| `field?: T \| null`            | Both — present-as-null _and_ absent are possible. Rare and usually a mistake.     |
| `field: T \| undefined` (rare) | Same shape as `field?: T` under `exactOptionalPropertyTypes: false`. Avoid.       |

With `exactOptionalPropertyTypes: true` on (recommended), `?` and `| undefined` are no longer interchangeable. The
checker forces you to choose.

```ts
// API response — field is always present, may be empty
interface PostMetadata {
    title: string;
    slug: string;
    published_at: string | null; // may have no publish date
    reading_time: number | null;
}

// Form payload — fields are optional in the input
interface PostUpdatePayload {
    title?: string;
    excerpt?: string;
    status?: PostStatus;
}
```

Do not use `undefined` for the absence of an API response field. The server either sends the key or does not; either way
the type system has a precise way to say so.

## Optional chaining (`?.`) and nullish coalescing (`??`)

Use them for nullish semantics. `&&` and `||` work on falsy values (`""`, `0`, `false`, `NaN`), which is almost never
what an API contract means.

```ts
// ❌ Falls back on the empty string
function displayName(user?: { profile?: { name?: string } }): string {
    return (user && user.profile && user.profile.name) || "Anonymous";
}

// ✅ Falls back only on null / undefined
function displayName(user?: { profile?: { name?: string } }): string {
    return user?.profile?.name ?? "Anonymous";
}
```

`displayName({ profile: { name: "" } })` returns `""` (correct) under the second form and `"Anonymous"` (wrong) under
the first.

`@typescript-eslint/prefer-nullish-coalescing` and `@typescript-eslint/prefer-optional-chain` catch these.

## Non-null assertion (`!`) — almost never

`value!` tells the compiler "trust me, this is not null/undefined". The compiler obeys; the runtime does not.

Acceptable uses are narrow:

- **Right after a proven invariant** that the checker cannot follow: e.g., immediately after `Array.find(...)` where you
  have proven via a constraint that the item exists.
- **Test code** where the failure mode is "the test crashes", which is fine.
- **At a boundary where you have just validated** — but in that case `as Type` or a type predicate is usually clearer.

The fix is almost always to narrow earlier:

```ts
// ❌
const user = users.find((u) => u.id === id)!;
```

```ts
// ✅ Narrow with a guard
const user = users.find((u) => u.id === id);
if (user === undefined) throw new Error(`User ${id} not found`);

// ✅ Or hoist the precondition
function requireUser(users: readonly User[], id: string): User {
    const user = users.find((u) => u.id === id);
    if (user === undefined) throw new Error(`User ${id} not found`);
    return user;
}
```

`@typescript-eslint/no-non-null-assertion` should warn in normal source and be acceptable in tests.

## `noUncheckedIndexedAccess`

With this flag on (recommended), `arr[i]` and `record[key]` types include `| undefined`. The runtime _is_ undefined for
out-of-range indexes; the type now says so.

```ts
const env: Record<string, string> = { NAME: "demo" };

// ❌ Crashes at runtime if NODE_ENV is unset
console.log(env.NODE_ENV.length);

// ✅
const mode = env["NODE_ENV"];
console.log(mode?.length ?? 0);
```

For known-stable lookups where you can prove the key exists, narrow with a guard first, or use a `Map` with `.get()` and
an explicit check.

## Validating unknown input

External input enters as `unknown`. Validate before use. Three escalating approaches:

### Hand-written type guard

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

Fine for one-off shapes and small libraries.

### Schema library (Zod, Valibot, ArkType, Effect Schema)

For non-trivial validation:

```ts
import { z } from "zod";

const User = z.object({ name: z.string() });
type User = z.infer<typeof User>;

export function parseUser(json: string): User {
    return User.parse(JSON.parse(json));
}
```

Pick one schema library per project. The output types should drive your domain types — do not maintain a parallel
`interface User` by hand.

### Standard Schema (`@standard-schema/spec`)

The Standard Schema spec (stable since 2024) lets one schema library produce schemas that other libraries can consume as
adapters. Useful when integrating with form libraries, tRPC, etc.

## Error throwing

Throw `Error` or a subclass with a useful message. Never throw strings, plain objects, or `undefined`.

```ts
// ❌
throw "invalid port";
throw { code: "E_INVALID", port: raw };

// ✅
throw new Error(`Invalid port: ${raw}`);
```

`@typescript-eslint/only-throw-error` enforces this.

### Named exception classes

When the failure has a recoverable shape that callers might want to catch by type, define a class. Name it after the \*
\*problem\*\*, not the category:

```ts
// ✅ The name states what went wrong
export class InvalidPort extends Error {
    constructor(readonly raw: string) {
        super(`Invalid port: ${raw}`);
        this.name = "InvalidPort";
    }
}

export class UnableToReadFile extends Error {
    constructor(
        readonly path: string,
        options?: { cause?: unknown },
    ) {
        super(`Unable to read file: ${path}`, options);
        this.name = "UnableToReadFile";
    }
}
```

Avoid `MyAppException`, `ValidationError` (without context), `ServiceFailure`. The base class already says "this is an
exception"; the name should describe the problem.

Use the `Error` `cause` constructor option to wrap underlying errors:

```ts
try {
    await fs.readFile(path, "utf8");
} catch (err) {
    throw new UnableToReadFile(path, { cause: err });
}
```

## Catching — `unknown`, narrow before reading

With `useUnknownInCatchVariables: true`, the catch variable is `unknown`. Narrow before using it.

```ts
try {
    await risky();
} catch (err: unknown) {
    if (err instanceof Error) {
        console.error(err.message);
    } else {
        console.error("Unknown failure", err);
    }
}
```

For library code that catches and rethrows, log enough context and preserve the original via `cause`:

```ts
try {
    // example logic elided for brevity
} catch (err) {
    throw new UnableToReadFile(path, { cause: err });
}
```

## Expected failures: return a result, do not throw

Exceptions are for _unexpected_ conditions — invariants broken, dependencies unreachable, programmer errors. _Expected_
domain failures (validation rejected the input, the lookup found nothing, the parse did not match) belong in the return
type.

### `T | null` for "found / not found"

```ts
function findUser(users: readonly User[], id: string): User | null {
    return users.find((u) => u.id === id) ?? null;
}
```

### Discriminated `Result<T, E>` for "succeeded / failed with reason"

```ts
type Result<T, E> = { ok: true; value: T } | { ok: false; error: E };

function parsePort(
    raw: string,
): Result<number, "not-a-number" | "out-of-range"> {
    const port = Number(raw);
    if (Number.isNaN(port)) return { ok: false, error: "not-a-number" };
    if (port < 1 || port > 65535) return { ok: false, error: "out-of-range" };
    return { ok: true, value: port };
}

const result = parsePort("8080");
if (result.ok) {
    // result.value: number
    listen(result.value);
} else {
    // result.error: "not-a-number" | "out-of-range"
    reportInvalidPort(result.error);
}
```

The shape of the error field can be a string literal union (cheap), a tagged class hierarchy (richer), or an instance of
a domain error class (still typed). Pick what fits.

### When to throw vs. return

| Situation                                                                   | Default                                                                                                           |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Programmer error / invariant violated                                       | Throw.                                                                                                            |
| External dependency unavailable                                             | Throw (with `cause`).                                                                                             |
| Input did not parse                                                         | Return `Result` or `null` if the caller is expected to handle it; throw if the caller cannot reasonably continue. |
| Lookup with "not found" as a normal answer                                  | Return `T \| null`.                                                                                               |
| Lookup where "not found" is unexpected and the caller has no way to recover | Throw a named error.                                                                                              |

The principle: **what should the caller do?** If "log and move on" is plausible, do not raise an exception. If "abort
the current operation" is the only reasonable answer, throw.

## `try`/`catch` with async — `return await` inside `try`

```ts
// ❌ The catch does not catch — the promise is returned, not awaited
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

`@typescript-eslint/return-await: ["error", "in-try-catch"]` catches this.
