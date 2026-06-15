---
name: best-practices-react
description: >-
    Use when writing, modifying, or reviewing React + TypeScript code (.tsx/.ts/.mts files containing JSX or React
    imports) — components, hooks, props, Server Components, client components, form actions, React Router 7 / TanStack
    Router / Next.js App Router routes, TanStack Query usage, Tailwind 4 styling, React Testing Library + Vitest tests.
    Applies to every React TypeScript task. Triggers for React 19 + React Compiler conventions: ref-as-prop (no
    `forwardRef`), no `React.FC`, no manual `useMemo`/`useCallback`/`React.memo` by default (Compiler handles it),
    server components by default in RSC frameworks, `use()` for promises, `useActionState` / `useFormStatus` /
    `useOptimistic` for forms, custom hooks named `use<Domain>`, effects as last resort. Use this even when the user
    does not explicitly mention React style.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# How to Write TypeScript + React

This skill captures an opinionated, framework-agnostic-within-React TypeScript style for the **React 19 + React Compiler
era** (mid-2026 baseline: React 19.2, React Compiler stable, Next.js 16, React Router 7.9, TanStack Query 5.90, TanStack
Router 1.114, Tailwind 4 with the Oxide engine, Vitest + React Testing Library, ESLint 10 flat config). Read alongside
the general TypeScript skill — everything in `how-to-write-typescript` still applies; this layer adds the React-specific
overrides.

## The One Idea

**Write the simplest React you can, and let the platform earn the complexity.** React 19's Compiler memoizes for you,
Server Components own data fetching, `use()` unwraps promises, ref-is-just-a-prop, and Actions own form lifecycles. The
pre-2024 mental model — `forwardRef` everywhere, `useMemo` everywhere, `useEffect` everywhere, a state library for
everything — produces code that is now actively _worse_ than what the platform gives you for free. Default to the
platform; reach for libraries when the platform is insufficient, not by reflex.

Two corollaries that shape everything below:

1. **Effects are a last resort, not a tool of first reach.** Most "effects" in junior codebases should be event
   handlers (state updates), derived values (computed during render), or server state (TanStack Query / `use()`). An
   `useEffect` should mean "synchronize React with an external system" — DOM, subscription, third-party widget. Nothing
   else.
2. **The Compiler memoizes for you.** Do not preemptively wrap things in `useMemo` / `useCallback` / `React.memo`. If a
   hot path measurably re-renders too often _with the Compiler enabled_, then memoize — but the manual memoization
   defaults from 2018-2023 React are now noise.

## When to Use This Skill

Use it for any of:

- Authoring `.tsx` files or `.ts` files containing React component types
- Designing component APIs (prop shapes, generics, polymorphism, ref forwarding)
- Writing custom hooks
- Configuring or wiring React Server Components, Server Actions, `use()`, Suspense, error boundaries
- Wiring TanStack Query / TanStack Router / React Router 7 / Next.js App Router / Next.js Pages
- Writing forms (React 19 Actions or react-hook-form), event handlers, controlled inputs
- Styling components with Tailwind 4 (or alternatives) and the `cn()` composition pattern
- Writing tests with React Testing Library + Vitest + MSW
- Reviewing React code for `useEffect` anti-patterns, redundant memoization, `any` event handlers, `forwardRef` in new
  code

Skip it for: non-React TypeScript work (use `how-to-write-typescript`), or pre-React-19 codebases pinned for
compatibility (mention the version so the conventions can be downscoped).

## Core Defaults

### 1. Component declaration: function, named export, explicit prop type — no `React.FC`

```tsx
// ✅
interface PostCardProps {
    readonly post: Post;
    readonly onSelect?: (post: Post) => void;
    readonly className?: string;
}

export function PostCard({
    post,
    onSelect,
    className,
}: PostCardProps): React.ReactNode {
    return (
        <article className={className} onClick={() => onSelect?.(post)}>
            <h2>{post.title}</h2>
            <p>{post.excerpt}</p>
        </article>
    );
}
```

Notes:

- `function`, not arrow, for components. Arrow components are fine but `function` gives you a stable function name in
  devtools and stack traces without ceremony.
- **Named export, not default.** Default exports are allowed only when the framework requires them (Next.js route
  segments and pages, `React.lazy()` targets, some module bundlers that key on default).
- **No `React.FC` / `React.FunctionComponent`.** It implicitly types `children`, defeats generic components, and pulls
  its weight nowhere. Type the props directly.
- Return type `React.ReactNode` (not `JSX.Element`) so the component composes with everything `ReactNode` accepts.
  Explicit return types on components are optional but help inference at boundaries.
- Props interfaces use `readonly` on every field. Props are immutable by contract; the type should say so.
- Suffix `...Props` is the convention; do not invent alternatives.

### 2. `ref` is just a prop in React 19 — no `forwardRef`

Old React (`forwardRef`) is obsolete in React 19. Declare `ref` in your props type and pass it through.

```tsx
// ✅ React 19
interface InputProps extends React.ComponentPropsWithoutRef<"input"> {
    readonly ref?: React.Ref<HTMLInputElement>;
}

export function Input({ ref, ...rest }: InputProps): React.ReactNode {
    return <input ref={ref} {...rest} />;
}

// ❌ pre-React-19 pattern — do not use in new code
const Input = React.forwardRef<HTMLInputElement, InputProps>((props, ref) => (
    <input ref={ref} {...props} />
));
```

The same rule applies to wrappers: take `ref` as a normal prop and forward it. The `ComponentPropsWithoutRef` /
`ComponentPropsWithRef` helpers from React are still the right primitive for extending DOM element props.

### 3. The React Compiler memoizes for you — stop reaching for `useMemo` / `useCallback` / `React.memo`

If the codebase has the React Compiler enabled (default in new Next.js 16 / Vite + React templates and most starters), \*
\*do not preemptively memoize\*\*.

```tsx
// ✅ Compiler era — let the compiler do its job
export function PostList({ posts, onSelect }: PostListProps) {
    const sorted = posts
        .slice()
        .sort((a, b) => b.publishedAt.localeCompare(a.publishedAt));
    const handleSelect = (post: Post) => onSelect(post.id);
    return sorted.map((post) => (
        <PostCard key={post.id} post={post} onSelect={handleSelect} />
    ));
}

// ❌ Manual memoization noise — the Compiler already handles this
export function PostList({ posts, onSelect }: PostListProps) {
    const sorted = useMemo(
        () =>
            posts
                .slice()
                .sort((a, b) => b.publishedAt.localeCompare(a.publishedAt)),
        [posts],
    );
    const handleSelect = useCallback(
        (post: Post) => onSelect(post.id),
        [onSelect],
    );
    return sorted.map((post) => (
        <PostCard key={post.id} post={post} onSelect={handleSelect} />
    ));
}
```

Three legitimate reasons to keep `useMemo` / `useCallback` / `React.memo`:

1. **Referential identity is part of the contract** — a memoized value is passed to a third-party library that uses
   identity for cache invalidation (e.g., older `useEffect`/dep-array consumers, react-dnd, virtualizers).
2. **The Compiler bailed out on this component** — verify with the `react-compiler-runtime` diagnostics or the ESLint
   plugin (`eslint-plugin-react-compiler`). The plugin highlights components the Compiler cannot optimize.
3. **A measured hot path** where profiling proves the manual memoization helps.

For incremental adoption in a partially-compiled codebase, use the `"use memo"` directive at the top of a function body
to opt that specific component or hook into compilation:

```tsx
function TodoList({ todos }: TodoListProps) {
    "use memo"; // opt this one component into the Compiler
    const sorted = todos.slice().sort((a, b) => a.dueAt.localeCompare(b.dueAt));
    return sorted.map((t) => <TodoItem key={t.id} todo={t} />);
}
```

The ESLint rule of choice is `eslint-plugin-react-compiler` (with `react-hooks/exhaustive-deps` from
`eslint-plugin-react-hooks` v6+).

### 4. Effects are a last resort

`useEffect` synchronizes React with an external system. That's it. If you do not have an external system, you do not
need an effect.

| Symptom                                                     | Replace with                                                                     |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------- |
| "I need to derive state from props"                         | Compute during render. State is for things that _change independently of props_. |
| "I need to reset state when props change"                   | A `key` prop on the component or a `useState` initializer keyed on a value.      |
| "I need to fetch data on mount"                             | Server Component, `use()` with a cached promise, or TanStack Query.              |
| "I need to set state in response to a click"                | Event handler.                                                                   |
| "I need to notify a parent when state changes"              | Lift state up; call the callback in the handler that changed it.                 |
| "I need a stable handler that closes over the latest state" | `useEffectEvent` (React 19.2+) — see references/react-19-features.md             |
| "I need to subscribe to a browser event / external store"   | This _is_ an effect. Use `useEffect` (or `useSyncExternalStore` for stores).     |
| "I need to interact with a DOM ref"                         | `useEffect` is appropriate; or use a ref callback for measurement.               |
| "I need to start a timer"                                   | Effect, with cleanup.                                                            |

The rule of thumb: **if removing the effect would lose no real behavior, remove the effect**.

### 5. Server-first in RSC frameworks

In any framework with React Server Components (Next.js App Router, TanStack Start, Waku, Remix/React-Router 7 in
framework mode with RSC opt-in):

- **Components are Server Components by default.** They run on the server, can be `async`, can fetch directly, and ship
  zero JS to the client.
- **Add `"use client"` only when you need it** — state, effects, event handlers, browser APIs, third-party client-only
  libraries.
- **Push the `"use client"` boundary as deep into the tree as possible.** A Server Component can render a small
  interactive island; a top-level `"use client"` page forfeits the entire architecture.
- **Server data fetched in Server Components passes to client components as props.** Do not duplicate the fetch on the
  client; lift the data into a Server Component and pass it down.

```tsx
// app/posts/page.tsx — Server Component, async, no "use client"
import { PostList } from "./post-list.js";
import { getPosts } from "@/data/posts.js";

export default async function PostsPage() {
    const posts = await getPosts(); // direct DB / API call
    return (
        <section>
            <h1>Posts</h1>
            <PostList posts={posts} />{" "}
            {/* client component for interactivity */}
        </section>
    );
}
```

```tsx
// app/posts/post-list.tsx — client component, narrow island of interactivity
"use client";

import { useState } from "react";

interface PostListProps {
    readonly posts: readonly Post[];
}

export function PostList({ posts }: PostListProps) {
    const [filter, setFilter] = useState("");
    const visible = posts.filter((p) =>
        p.title.toLowerCase().includes(filter.toLowerCase()),
    );
    return (
        <>
            <input value={filter} onChange={(e) => setFilter(e.target.value)} />
            <ul>
                {visible.map((p) => (
                    <li key={p.id}>{p.title}</li>
                ))}
            </ul>
        </>
    );
}
```

### 6. State management: pick the right tool for the kind of state

| Kind of state                                                                      | Tool                                                                                                                     |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Server state (anything fetched from a server, cached, retried, paginated, mutated) | **TanStack Query** (or Server Components + Server Actions in RSC frameworks)                                             |
| Client state shared across a screen but not the whole app                          | Lifted `useState` or `useReducer`; React Context for "ambient" data (theme, auth user)                                   |
| Global client state (multi-screen, multi-component)                                | **Zustand** (simple) or **Jotai** (atomic / fine-grained). Avoid Redux for greenfield.                                   |
| URL state (filters, pagination, modals, tabs)                                      | The router's search params API (TanStack Router is the gold standard; React Router 7 and Next.js `useSearchParams` work) |
| Form state                                                                         | React 19 Actions + `useActionState`, or `react-hook-form` for client-heavy forms                                         |

**Do not put server data in Redux / Zustand.** Server state has caching, staleness, retries, dedupe — TanStack Query
owns all of it. Mixing server data into client state stores is a recipe for stale data and complicated invalidation.

### 7. Forms use React 19 Actions or react-hook-form — pick by need

```tsx
// ✅ React 19 Action — server-driven, progressive enhancement, no client JS needed for submission
"use client";

import { useActionState } from "react";
import { createPost } from "./actions.js";

interface FormState {
    error: string | null;
}

export function CreatePostForm() {
    const [state, formAction, isPending] = useActionState<FormState, FormData>(
        createPost,
        { error: null },
    );
    return (
        <form action={formAction}>
            <input name="title" required />
            <textarea name="content" required />
            {state.error !== null && <p role="alert">{state.error}</p>}
            <button type="submit" disabled={isPending}>
                {isPending ? "Saving…" : "Save"}
            </button>
        </form>
    );
}
```

For client-heavy forms with complex validation, multi-step wizards, dynamic field arrays, or schema-driven generation, \*
\*react-hook-form + a schema resolver (Zod / Valibot / ArkType)\*\* is still the right tool. See `references/forms.md`.

### 8. Event handlers: typed, no `any`

```tsx
// ❌
function onClick(e: any) {
    e.target.value;
}

// ✅
function onClick(event: React.MouseEvent<HTMLButtonElement>): void {
    /* ... */
}
function onChange(event: React.ChangeEvent<HTMLInputElement>): void {
    /* ... */
}
function onSubmit(event: React.FormEvent<HTMLFormElement>): void {
    /* ... */
}
```

Inline handlers are fine — the React Compiler handles the identity:

```tsx
<button onClick={() => setOpen(true)}>Open</button>
```

### 9. Children and slots

```tsx
// ✅ "anything renderable" — most common
interface CardProps {
    readonly children: React.ReactNode;
}

// ✅ "exactly one element" — rare, but useful for cloneElement-style wrappers
interface TooltipProps {
    readonly children: React.ReactElement;
    readonly content: string;
}

// ✅ "a render function" — for headless components
interface ListProps<T> {
    readonly items: readonly T[];
    readonly children: (item: T, index: number) => React.ReactNode;
}
```

Avoid `ReactChild` and `ReactFragment` (deprecated). Avoid `JSX.Element` for `children` — it is too narrow.

### 10. Discriminated unions for component variants

A `Button` with `variant="primary" | "secondary" | "ghost"` is a discriminated union for _values_. When the **shape of
props depends on the variant**, use a discriminated union of the props themselves:

```tsx
type ButtonProps =
    | { readonly variant: "link"; readonly href: string }
    | { readonly variant: "button"; readonly onClick: () => void };

export function Button(props: ButtonProps): React.ReactNode {
    if (props.variant === "link") return <a href={props.href}>…</a>;
    return <button onClick={props.onClick}>…</button>;
}
```

The compiler now refuses `<Button variant="link" onClick={...} />` and `<Button variant="button" href="..." />`. The
shape _is_ the contract.

### 11. Custom hooks: `use<Domain>`, plain object return

```tsx
// ✅ Domain name; returns an object; the surface is the public API
export function useDebouncedValue<T>(value: T, delayMs: number): T {
    const [debounced, setDebounced] = useState(value);
    useEffect(() => {
        const id = setTimeout(() => setDebounced(value), delayMs);
        return () => clearTimeout(id);
    }, [value, delayMs]);
    return debounced;
}

export function useFeatureFlag(key: string): {
    readonly enabled: boolean;
    readonly variant: string | null;
} {
    // ...
    return { enabled, variant };
}
```

- Name starts with `use` and ends with a domain noun (`useUser`, `usePostList`) or a behavior (`useDebouncedValue`,
  `useIsomorphicLayoutEffect`). Not `useState2`, not `useHelper`.
- Return an object when there is more than one value, or when callers will use named destructuring (
  `const { data, isLoading, error } = useUser(id)`).
- Return a tuple only when the values are positional like `useState` (`const [value, setValue] = useToggle()`).
- The Rules of Hooks (no calling hooks conditionally, no calling hooks outside a component or another hook) are enforced
  by `eslint-plugin-react-hooks`. Leave them on.

### 12. Tailwind 4 + `cn()` for composition

Tailwind 4 (Oxide engine) is the default styling story for new React projects in 2026. Setup in CSS:

```css
/* app/globals.css */
@import "tailwindcss";
```

The `cn()` helper (clsx + tailwind-merge) is the composition primitive:

```tsx
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]): string {
    return twMerge(clsx(inputs));
}

// usage
<button
    className={cn(
        "rounded-md px-4 py-2 font-medium",
        variant === "primary" && "bg-blue-600 text-white",
        variant === "ghost" && "bg-transparent text-blue-600",
        className, // caller override always wins
    )}
/>;
```

`tailwind-merge` resolves conflicts so caller overrides actually win (`<Button className="px-8" />` beats the
component's default `px-4`).

For headless component primitives, **Radix** + Tailwind (shadcn/ui pattern) is the dominant idiom — you copy components
into your repo and own them.

### 13. Routing — pick one and commit

| You are using                              | Routing API                                                                                                                               |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Next.js App Router                         | File-based routes under `app/`. Server Components by default. `params` is a Promise in Next.js 15+ — `await params` in the route handler. |
| React Router 7 (framework or library mode) | `routes.ts` config, file-conventions optional, loaders / actions, typed search params                                                     |
| TanStack Router                            | `routeTree.gen.ts` with file-based routes (recommended) or programmatic. Type-safe everything (params, search, links).                    |

Three rules across all of them:

- **Use the framework's typed link / navigate APIs.** A bare `<a href="/posts/123">` skips client-side navigation;
  `<Link to="/posts/123">` doesn't. In TanStack Router, the link API enforces param/search shape at compile time.
- **Validate search params at the boundary.** The router's parser (TanStack Router) or a Zod schema (others) makes the
  URL a strongly-typed data source.
- **Loaders for data, when available.** React Router 7 loaders and TanStack Router `loader` integrate with TanStack
  Query and avoid the "fetch in `useEffect`" pattern.

### 14. Testing: Vitest + RTL + MSW

```tsx
// post-card.test.tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { expect, test, vi } from "vitest";
import { PostCard } from "./post-card.js";

test("calls onSelect when clicked", async () => {
    const onSelect = vi.fn();
    render(<PostCard post={samplePost} onSelect={onSelect} />);
    await userEvent.click(screen.getByRole("article"));
    expect(onSelect).toHaveBeenCalledWith(samplePost);
});
```

Rules:

- **Query by role** (`getByRole`), then by accessible name. `getByText` is acceptable for visible copy; `getByTestId` is
  the last resort.
- **`userEvent`, not `fireEvent`.** `userEvent` simulates real interaction (focus, keypress sequence, etc.).
- **`await screen.findBy*` for async appearances.** Never `setTimeout` in a test.
- **MSW for API mocks.** Mock the network, not the function. The test still exercises your data layer.
- **Playwright for end-to-end and for component testing where browser rendering matters.**

See `references/testing.md` for component-level patterns, async-render gotchas, and React 19 Activity testing.

### 15. Boundaries: validate `unknown` from the outside, types flow inward

Every value crossing into your React tree from outside the type system — `fetch`, `localStorage`, URL params,
`window.postMessage`, route loaders — enters as `unknown` and is validated _before_ it becomes a typed domain object.
Inside the app, types are precise and `unknown` does not appear.

```ts
import { z } from "zod";

const Post = z.object({
    id: z.string(),
    title: z.string(),
    excerpt: z.string(),
    published_at: z.string().nullable(),
    reading_time: z.number().nullable(),
});

export type Post = z.infer<typeof Post>;

export async function getPost(id: string): Promise<Post> {
    const response = await fetch(`/api/posts/${id}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return Post.parse(await response.json());
}
```

The same schema can drive form validation (via `@hookform/resolvers/zod` or React 19 Action validation) and TanStack
Query type inference.

## Quick Triage Table

When the task is unclear, use this to pick the canonical default:

| Situation                                     | Default choice                                                                     |
| --------------------------------------------- | ---------------------------------------------------------------------------------- |
| New component, no special behavior            | Function declaration, named export, explicit `Props` interface, `readonly` fields  |
| Component needs to expose a DOM ref           | `ref` as a normal prop (React 19), `React.Ref<HTMLElement>`                        |
| Component variant changes prop shape          | Discriminated union for the _props themselves_                                     |
| "I need to memoize this" (no measurement yet) | Don't. Trust the Compiler.                                                         |
| "I need to fetch data on mount"               | RSC if available, else TanStack Query, else `use()` + a cached promise             |
| "I need to derive state"                      | Compute during render; do not `useEffect`+`setState`                               |
| "I need to react to a prop change"            | Compute during render or `key=` to reset state; do not `useEffect`                 |
| Form submission                               | React 19 Action + `useActionState`; or react-hook-form + Zod for client-rich forms |
| Global client state                           | Zustand or Jotai; Context for ambient values; never Redux greenfield               |
| Server state cache                            | TanStack Query                                                                     |
| URL search params                             | Router's typed search-param API; validate with the parser or Zod                   |
| Styling                                       | Tailwind 4 + `cn()`; Radix for primitives; shadcn pattern (own the components)     |
| Test of behavior                              | RTL `getByRole` + `userEvent`; MSW for network                                     |
| Test of types                                 | `tsd` or `expectTypeOf` (Vitest typecheck mode)                                    |
| Validation at trust boundary                  | Zod (or Valibot / ArkType / Effect Schema) — pick one and stay consistent          |
| `forwardRef` in new code                      | Never. Use `ref` as a prop.                                                        |

## Reference Files

Read the relevant file when SKILL.md leaves a judgment call open:

- `references/components-and-props.md` — Component declaration patterns, prop typing, `ComponentProps<T>`, generic
  components, polymorphic components (`as` prop), children patterns, ref-as-prop in depth, discriminated component
  variants.
- `references/hooks.md` — Rules of hooks, custom hook design, naming, return shapes, `useState` initializers,
  `useReducer` when, `useEffect` anti-patterns vs. legitimate effects, `useSyncExternalStore`, hook composition, common
  custom hooks worth writing.
- `references/react-19-features.md` — `use()` for promises and Context, Actions and `useActionState`, `useFormStatus`,
  `useOptimistic`, ref-as-prop migration, Activity component (React 19.2), `useEffectEvent` (React 19.2), Document
  Metadata, async transitions, async error handling.
- `references/server-components.md` — RSC mental model, `"use client"` / `"use server"` directives, async components,
  data fetching in Server Components, Server Actions, Suspense + streaming, the "push the client boundary deep" pattern,
  common composition mistakes, params/searchParams as Promise (Next.js 15+).
- `references/state-management.md` — Server state vs client state, TanStack Query patterns (queries, mutations,
  optimistic updates, Suspense mode), Zustand and Jotai (when each), React Context (when and how), URL as a state
  primitive, the `useReducer` + Context pattern, when global state actually wins.
- `references/forms.md` — React 19 form Actions in depth, `useActionState`, `useFormStatus`, `useOptimistic` for
  optimistic mutations, react-hook-form patterns with Zod resolvers, controlled vs uncontrolled inputs, event typing,
  multi-step / array-field forms.
- `references/routing.md` — React Router 7 (framework + library mode, loaders, actions, typed routes), TanStack Router (
  file-based routes, type-safe links, search params, integration with TanStack Query), Next.js App Router (segments,
  layouts, loading.tsx, error.tsx, params/searchParams), shared patterns.
- `references/styling.md` — Tailwind 4 (Oxide engine, `@import "tailwindcss"`, CSS variables for theming, no config most
  of the time), the `cn()` helper, Radix primitives + Tailwind composition, shadcn/ui's "own-the-code" pattern,
  alternatives (vanilla-extract, Panda CSS, CSS Modules), dark mode strategies.
- `references/testing.md` — Vitest + RTL + MSW setup, component test patterns, async-render gotchas, query priority (
  `getByRole` first), testing forms / Server Components / Suspense, Playwright component testing, type-level tests for
  component APIs.
- `references/performance.md` — React Compiler in depth (what it optimizes, what it bails on, the `"use memo"`
  directive), why pre-Compiler memoization is now noise, when manual memoization still earns its keep, Suspense
  boundaries for streaming, code splitting, Server Components as a perf tool, `<Activity>` for hide-without-unmount,
  virtualization.

## Common Mistakes

| Mistake                                                               | Fix                                                                                   |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `React.FC<Props>`                                                     | Explicit `({ ... }: Props): React.ReactNode` — no `React.FC` in new code              |
| `forwardRef` in React 19 code                                         | `ref` is just a prop now                                                              |
| `useMemo` / `useCallback` "to be safe"                                | Trust the Compiler; memoize on measurement, not reflex                                |
| `useEffect` to derive state                                           | Compute during render                                                                 |
| `useEffect(() => setFoo(props.bar))`                                  | Use `props.bar` directly, or `key={props.bar}` to reset state                         |
| `useEffect` for data fetching                                         | RSC + Server Actions, TanStack Query, or `use()` with a cached promise                |
| `e: any` on handlers                                                  | `React.MouseEvent<HTMLButtonElement>` etc.                                            |
| `as` cast on `event.target` for inputs                                | Type the handler as `React.ChangeEvent<HTMLInputElement>` and read `.target.value`    |
| `JSX.Element` as a children type                                      | `React.ReactNode`                                                                     |
| Default export of a component (non-framework context)                 | Named export                                                                          |
| `useState<string \| undefined>(undefined)` then `value!` everywhere   | Model the initial state explicitly; or use a discriminated `loading` / `loaded` state |
| Server data stored in Zustand / Redux                                 | TanStack Query owns server data                                                       |
| `"use client"` at the top of a page that mostly renders static markup | Push the client boundary down to the actual interactive island                        |
| `<a href="/posts/123">` for internal nav                              | Framework-typed `<Link to="...">`                                                     |
| `getByTestId` everywhere in tests                                     | `getByRole` + accessible name                                                         |
| `enum Variant`                                                        | `type Variant = "primary" \| "secondary" \| "ghost"`                                  |

## Pre-Commit Self-Check

Before declaring a React change done:

- [ ] No `React.FC`. Props are an explicit `interface ...Props` with `readonly` fields.
- [ ] No `forwardRef` in new code. `ref` is in the props type.
- [ ] No manual `useMemo` / `useCallback` / `React.memo` unless a comment explains the reason (third-party identity,
      Compiler bailout, measured hot path).
- [ ] Every `useEffect` actually synchronizes with an external system. If not, replace it.
- [ ] Server data flows through TanStack Query, Server Components, or `use()` — not `useEffect` + `fetch`.
- [ ] `"use client"` is at the deepest possible boundary.
- [ ] Event handlers are typed (`React.MouseEvent<...>`, `React.ChangeEvent<...>`, etc.). No `any`.
- [ ] Component variants whose shape changes use a discriminated union.
- [ ] Custom hooks start with `use<Domain>` and return a named-property object (or a `useState`-shaped tuple).
- [ ] Forms either use a React 19 Action + `useActionState`, or react-hook-form + a Zod schema.
- [ ] External input (fetch, URL, storage, postMessage) is validated against a schema before becoming a typed domain
      object.
- [ ] Tests use `getByRole` and `userEvent`. MSW mocks the network, not your data layer.
- [ ] `tsc --noEmit` and `eslint` both clean. `eslint-plugin-react-hooks` and (where applicable)
      `eslint-plugin-react-compiler` are configured.

When in doubt: prefer the platform's primitives over libraries. Prefer Server Components over client state. Prefer
rendering over effects. Prefer the Compiler over manual memoization. Prefer accessible roles over test ids.
