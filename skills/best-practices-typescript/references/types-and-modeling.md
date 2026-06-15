# Types and Domain Modeling

How to shape data, interfaces, generics, and unions so the types match the domain and the checker stays cheap.

## interface vs. type — when each one belongs

| Use `interface` for                               | Use `type` for                                             |
| ------------------------------------------------- | ---------------------------------------------------------- |
| Object record shapes                              | Unions (`A \| B`), discriminated unions                    |
| Public structural contracts a consumer implements | Tuples (`[number, string]`)                                |
| Class contracts                                   | Aliases of primitives / functions                          |
| Anything you might extend with `extends`          | Mapped types, conditional types, utility-type compositions |
| API payloads, value-object-like records           | Anything that is not "an object with these fields"         |

```ts
// ✅ Object shape — interface
interface User {
    id: string;
    email: string;
    active: boolean;
}

// ✅ Composing object shapes — interface extends interface
interface Audited extends User {
    createdAt: Date;
    updatedAt: Date;
}

// ✅ Derived alias / non-object form — type
type UserId = User["id"];
type UserState = "active" | "disabled";
type Result<T, E> = { ok: true; value: T } | { ok: false; error: E };
```

### Why prefer interfaces for object shapes

Interfaces produce a single flat object type, detect conflicts directly during declaration merging, display better in
errors, and cache cheaper in the checker. Long intersections (`A & B & C & D`) defeat that caching and produce
harder-to-read errors.

```ts
// ❌ Intersection masquerading as a record shape
type User = { id: string } & { email: string } & { active: boolean };

// ✅ One interface
interface User {
    id: string;
    email: string;
    active: boolean;
}
```

For a "user with extra fields", `interface User extends Entity, Audited` beats `type User = Entity & Audited & { ... }`.

## Generics — preserve a relationship or do not introduce one

The only good reason to introduce a generic is to preserve a relationship between inputs and outputs (or between two
inputs). If the relationship is incidental, the generic is noise.

```ts
// ✅ Preserves T from input to output
function first<T>(items: readonly T[]): T | undefined {
    return items[0];
}

// ❌ Generic noise — caller passes a number and gets a number, but the function does nothing with the type
function identity<T>(value: T): T {
    console.log("processed");
    return value;
}
```

### Inference over explicit type arguments

Let TypeScript infer when it can. Explicit `<...>` arguments at call sites are usually a sign that the function
signature is wrong.

```ts
const xs = first(["a", "b"]); // T inferred as string
const ys = first<number>([1, 2]); // explicit usually unnecessary
```

### Constraints — only when they buy something

`<T extends Foo>` should mean "the implementation uses Foo-ness". A constraint that exists only so the compiler will let
you pass the value through is overhead.

```ts
// ✅ Constraint earns its keep — code reads .length
function longest<T extends { length: number }>(
    xs: readonly T[],
): T | undefined {
    return xs.reduce<T | undefined>(
        (acc, x) => (acc === undefined || x.length > acc.length ? x : acc),
        undefined,
    );
}
```

### `satisfies` — validate shape without widening

`satisfies` is the right answer when you want to check a value against a type _without losing the precise inferred
type_. Use it instead of `as Type` annotations on object literals.

```ts
type ThemeKey = "primary" | "secondary";

const theme = {
    primary: "#0af",
    secondary: "#333",
} satisfies Record<ThemeKey, string>;

theme.primary; // string — literal type still preserved
// theme.tertiary; // ❌ caught at compile time
```

vs. `const theme: Record<ThemeKey, string> = { ... }`, which widens the value types to `string` and forgets that
`primary` is `"#0af"`.

### `as const` — freeze a literal at the type level

```ts
const config = { retries: 3, mode: "fast" } as const;
// config.retries: 3 (not number)
// config.mode: "fast" (not string)
```

Combine with `satisfies` when you also want type-side validation:

```ts
const config = { retries: 3, mode: "fast" } as const satisfies AppConfig;
```

## Discriminated unions for state

When a value can be in one of several states, encode each state explicitly with a shared discriminant property. Then
narrow with `switch` on the discriminant, and use a `never` assignment in the default branch to make missing variants a
compile error.

```ts
type AsyncState<T> =
    | { status: "idle" }
    | { status: "loading" }
    | { status: "success"; data: T }
    | { status: "error"; error: Error };

function describe<T>(state: AsyncState<T>): string {
    switch (state.status) {
        case "idle":
            return "not started";
        case "loading":
            return "loading…";
        case "success":
            return `loaded ${typeof state.data}`;
        case "error":
            return state.error.message;
        default: {
            const unreachable: never = state;
            return unreachable;
        }
    }
}
```

Why this beats a flat object with optional fields:

- The shape matches the runtime truth — `data` does not exist in the `idle` state.
- Adding a new variant (e.g., `"cancelled"`) becomes a compile error everywhere a switch is missing.
- `state.data` is typed `T` (not `T | undefined`) inside the `"success"` branch.

## Avoid huge anonymous unions; factor shared structure

```ts
// ❌ One big anonymous discriminated union — checker-expensive, harder to read
type Event =
    | { kind: "start"; at: number; requestId: string }
    | { kind: "stop"; at: number; requestId: string }
    | { kind: "retry"; at: number; requestId: string }
    | { kind: "timeout"; at: number; requestId: string };
```

```ts
// ✅ Shared base, named variants
interface BaseEvent {
    at: number;
    requestId: string;
}
interface StartEvent extends BaseEvent {
    kind: "start";
}
interface StopEvent extends BaseEvent {
    kind: "stop";
}
interface RetryEvent extends BaseEvent {
    kind: "retry";
}
interface TimeoutEvent extends BaseEvent {
    kind: "timeout";
}

type Event = StartEvent | StopEvent | RetryEvent | TimeoutEvent;
```

Union reduction can become quadratic for large unions; named members and a shared base type keep the checker fast and
the code grep-friendly.

## `as const` objects + literal unions in place of `enum`

```ts
// ❌ enum — runtime quirks, isolatedModules friction, no tree shaking
enum Status {
    Pending = "pending",
    Done = "done",
}

// ❌ const enum — even worse in mixed toolchains; banned in published code
const enum Kind {
    A,
    B,
}

// ✅ as const object + derived union
export const Status = {
    Pending: "pending",
    Done: "done",
} as const;
export type Status = (typeof Status)[keyof typeof Status];
```

Use a real `enum` only when you specifically need the runtime enum object (e.g., interop with a library that requires
it). Otherwise the `as const` pattern gives you runtime values _and_ precise types.

## Utility types

The built-in utility types are the right answer most of the time — do not invent a parallel interface when `Pick`,
`Partial`, `Omit`, `Readonly`, `Required`, or `ReturnType` says it:

```ts
type PostFormData = Pick<BlogPost, "title" | "slug" | "excerpt"> & {
    content: string;
};
type PostUpdatePayload = Partial<
    Pick<BlogPost, "title" | "excerpt" | "status">
>;
type ApiResponse<T> = Readonly<{ data: T; cursor: string | null }>;
```

When a derived utility type is used in many places and gets complicated, **name it**. Naming complex conditional /
mapped types lets the checker cache the result and gives error messages a useful symbol to print.

```ts
// ❌ Inlined and repeated everywhere
function box<U>(
    x: U,
): U extends string ? { s: U } : U extends number ? { n: U } : { v: U };

// ✅ Named — cheaper to check, easier to read
type GetResult<U> = U extends string
    ? { s: U }
    : U extends number
      ? { n: U }
      : { v: U };

function box<U>(x: U): GetResult<U>;
```

## Branded types for primitive wrappers

Two `string`s in the same function signature are interchangeable. Sometimes that is wrong — `PostSlug` and
`EmailAddress` are both strings, but you do not want a function expecting one to accept the other.

```ts
type Brand<T, B> = T & { readonly __brand: B };
type PostSlug = Brand<string, "PostSlug">;
type EmailAddress = Brand<string, "EmailAddress">;

function postSlug(value: string): PostSlug {
    if (!/^[a-z0-9-]+$/.test(value))
        throw new Error(`Invalid post slug: ${value}`);
    return value as PostSlug;
}

function emailAddress(value: string): EmailAddress {
    if (!value.includes("@")) throw new Error(`Invalid email: ${value}`);
    return value as EmailAddress;
}

declare function findPost(slug: PostSlug): unknown;

findPost(postSlug("my-post")); // ✅
findPost(emailAddress("a@b.com")); // ❌ compile error
```

Branded types are free at runtime (the brand property is purely a type-side fiction). Use them when:

- A primitive needs validation before use (UUID, slug, email, ISO timestamp).
- Two same-typed values would otherwise be silently swappable.
- A class would be overkill (no behavior, no methods).

## Value objects — interface vs. class

| When the wrapper has only data         | When the wrapper has behavior                              |
| -------------------------------------- | ---------------------------------------------------------- |
| `interface` with `readonly` properties | `class` with `readonly` constructor parameters and methods |

```ts
// ✅ Pure data — readonly interface
export interface BlogPost {
    readonly title: string;
    readonly slug: string;
    readonly excerpt: string;
    readonly content?: string;
    readonly published_at: string;
    readonly reading_time: number | null;
    readonly categories: readonly BlogCategory[];
}

export interface BlogCategory {
    readonly name: string;
    readonly slug: string;
}
```

```ts
// ✅ Data + behavior — class with readonly fields
class Money {
    constructor(
        public readonly amount: number, // minor units (cents)
        public readonly currency: string, // ISO 4217
    ) {
        if (amount < 0) throw new Error("Money amount cannot be negative.");
    }

    add(other: Money): Money {
        if (this.currency !== other.currency) {
            throw new Error("Cannot add money of different currencies.");
        }
        return new Money(this.amount + other.amount, this.currency);
    }

    format(): string {
        return (this.amount / 100).toFixed(2) + " " + this.currency;
    }

    isZero(): boolean {
        return this.amount === 0;
    }
}
```

## Naming a domain — every concept gets a name

The rule: **if a concept has a name in the domain and carries more than one piece of state, it deserves a named
interface.**

The smell that the rule is being violated:

- The same anonymous shape is passed to more than one function: `{ user: User; tenant: Tenant; permissions: string[] }`.
- A function returns an object and the caller has to know which keys exist.
- Type errors print `{ id: string; email: string; ... }` instead of a symbol the reader recognizes.

Name it. Use `interface RequestContext`, not `{ method: string; uri: string; userAgent: string }`. The name doubles as
the search anchor (`grep RequestContext`) and as the unit of refactoring.

## Overloads — only when the return type depends on the call shape

```ts
// ❌ Overloads not earning their keep — a union does the same job
function size(value: string): number;
function size(value: readonly unknown[]): number;
function size(value: string | readonly unknown[]): number {
    return value.length;
}

// ✅ Just a union parameter
function size(value: string | readonly unknown[]): number {
    return value.length;
}
```

Overloads are appropriate when the _return type_ truly depends on which call shape was used:

```ts
function toDate(timestamp: number): Date;
function toDate(year: number, month: number, day: number): Date;
function toDate(a: number, b?: number, c?: number): Date {
    return b === undefined || c === undefined ? new Date(a) : new Date(a, b, c);
}
```

Keep the implementation signature private (it is invisible to callers) and the overload list adjacent to it.

## Mirroring server-side models

When TypeScript models cross a network boundary from a server-side type system (PHP value objects, Pydantic, Go
structs), mirror the wire format exactly:

- Same field names (whatever the JSON output uses — `snake_case` if the server emits snake_case).
- Same types (`Date` → ISO 8601 `string`; numeric ID → `string` or `number` to match server).
- Same nullability (`?string` → `string | null` when always present, `string?` when optional).

Do not silently rename to `camelCase` in the type unless the JSON itself is camelCase. Renaming hides drift and makes
server logs harder to grep.
