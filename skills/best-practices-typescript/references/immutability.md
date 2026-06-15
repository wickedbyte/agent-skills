# Immutability

`readonly`, the wither pattern, and where mutability is justified.

## `readonly` on every property of data interfaces

Anything that represents a captured fact — value object, domain event, API payload, request context — gets `readonly` on
every property.

```ts
interface StackFrame {
    readonly file: string;
    readonly line: number;
    readonly function: string;
    readonly class: string | null;
    readonly type: "::" | "->" | null;
}
```

Why default to `readonly`:

- It documents intent. A reader sees the type and knows mutation is not expected.
- The compiler refuses to let callers mutate the property.
- Frozen-shape objects are friendlier to V8's hidden-class optimization (no shape churn from `delete` or reassignment).

## `Readonly<T>` wraps an existing type

If you cannot edit the source interface but want a read-only view of it:

```ts
function describe(user: Readonly<User>): string {
    return user.name;
}
```

`Readonly<T>` is shallow — the same caveat below applies.

## `readonly` is shallow — model nested immutability explicitly

`readonly tags: string[]` prevents reassigning `tags`, but does **not** prevent `user.tags.push(...)`. To mean "do not
mutate the array either", use `readonly string[]`:

```ts
// ❌ Caller can still mutate the array
interface User {
    readonly name: string;
    readonly tags: string[];
}

// ✅ Both the binding and the array contents are read-only
interface User {
    readonly name: string;
    readonly tags: readonly string[];
}
```

For nested objects, use `Readonly<...>` on the nested type or wrap the whole thing:

```ts
type DeepReadonlyUser = Readonly<{
    name: string;
    profile: Readonly<{
        email: string;
        addresses: readonly Address[];
    }>;
}>;
```

A general-purpose `DeepReadonly<T>` is sometimes useful but tends to interact badly with branded types and class
instances. Prefer modeling immutability at the boundary that matters.

## Wither pattern — return a new object instead of mutating

When a caller wants "the same value but with one field changed", return a new object. The spread operator does the work:

```ts
interface PostMetadata {
    readonly title: string;
    readonly slug: string;
    readonly status: PostStatus;
    readonly publishedAt?: Date;
}

function withStatus(post: PostMetadata, status: PostStatus): PostMetadata {
    return { ...post, status };
}

function withPublishedAt(post: PostMetadata, date: Date): PostMetadata {
    return { ...post, publishedAt: date };
}
```

The naming convention `with<FieldName>` makes intent obvious at call sites:

```ts
const published = withPublishedAt(withStatus(draft, "published"), new Date());
```

For arrays, the same idea using non-mutating array methods (`.toSorted()`, `.toReversed()`, `.toSpliced()`,
`.with(i, value)`, or `[...arr, x]`):

```ts
const next = [...users, newUser]; // append
const updated = users.with(i, modifiedUser); // replace at index
const filtered = users.filter((u) => u.active); // remove
const sorted = users.toSorted((a, b) => a.name.localeCompare(b.name));
```

`.toSorted` / `.toReversed` / `.toSpliced` / `.with` are stable in modern runtimes and replace the old mutating pairs.

## Legitimate mutable state — wrap it in a class

When state genuinely changes over time (caches, configuration that gets installed once, connection pools), put it inside
a class with private fields and explicit mutation methods. The class is the boundary that limits where the mutation can
happen.

```ts
class Graveyard {
    private static config: GraveyardConfiguration | null = null;

    static configure(config: GraveyardConfiguration): GraveyardConfiguration {
        return (Graveyard.config = config);
    }

    static getConfig(): GraveyardConfiguration {
        return (Graveyard.config ??= new GraveyardConfiguration());
    }

    static reset(): void {
        Graveyard.config = null;
    }
}
```

The principle: mutation needs a _named place_. A global mutable variable in module scope is harder to reason about than
a class with a small mutation API.

## Mixed mutability — annotate the exception

When one field of an otherwise-immutable object is intentionally mutable, mark it and explain why. A stoppable event is
the canonical example:

```ts
class TombstoneActivated {
    readonly id: string;
    readonly reference: string;
    propagate = true; // Intentionally mutable: stoppable event pattern.

    constructor(
        readonly message: string,
        readonly caller: StackFrame,
        readonly trace: StackFrame[] = [],
        readonly extra: Record<string, unknown> = {},
        readonly timestamp: Date = new Date(),
    ) {
        this.reference = `${caller.class}${caller.type}${caller.function}`;
        this.id = hashXXH3(this.reference + message);
    }
}
```

A listener calls `event.propagate = false` to stop the chain. The comment justifies why this single field breaks the
otherwise-`readonly` rule.

## When `Object.freeze` adds value

`Object.freeze(obj)` makes the object's properties read-only at runtime — it actually prevents mutation, not just at the
type level. Use it for module-level constants that ship to consumers who might receive a reference:

```ts
export const DEFAULTS = Object.freeze({
    retries: 3,
    timeoutMs: 5000,
} as const);
```

Two notes:

- `freeze` is shallow. Nested objects are still mutable. Use a deep-freeze helper or accept the limitation.
- `freeze` has a small runtime cost. Do not put it on hot-path objects.

## When mutation is fine

A local accumulator inside a single function is the obvious case:

```ts
function summarize(xs: readonly number[]): { count: number; sum: number } {
    let count = 0;
    let sum = 0;
    for (const x of xs) {
        if (x > 0) {
            count++;
            sum += x;
        }
    }
    return { count, sum };
}
```

The mutation never escapes the function. The returned object is a fresh value. This is correct and (on a hot path) much
cheaper than `xs.filter(...).reduce(...)`.

The rule of thumb: **mutate freely inside the function; return values, not references to internal state**.
