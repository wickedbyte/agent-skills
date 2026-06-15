# Performance

React Compiler changes the game. Suspense, Server Components, and the Activity component are the new performance
primitives. Manual memoization is reserved for measured hot paths.

## The Compiler is the new default

The React Compiler (stable, integrated into `eslint-plugin-react-compiler` and React's runtime) statically analyzes your
components and inserts the optimal memoization. The pre-2024 mental model of `useMemo` / `useCallback` / `React.memo`
everywhere is now an _anti-pattern_ — manual memoization adds noise, can prevent the Compiler from optimizing further,
and tends to be wrong (forgotten deps, stale closures).

### What the Compiler does

```jsx
// You write this
function ExpensiveComponent({ data, onClick }) {
    const processedData = expensiveProcessing(data);
    const handleClick = (item) => onClick(item.id);
    return (
        <div>
            {processedData.map((item) => (
                <Item key={item.id} onClick={() => handleClick(item)} />
            ))}
        </div>
    );
}

// The Compiler effectively produces this — caches keyed on inputs, identity preserved across renders when inputs are stable
```

The runtime hook `react/compiler-runtime` is what makes this work. The output is more efficient than what most humans
write by hand because the Compiler has whole-component knowledge.

### Enabling it

In Next.js 16, the Compiler is enabled by default in new projects. In Vite + React, install
`babel-plugin-react-compiler` and configure it through `@vitejs/plugin-react`:

```ts
// vite.config.ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
    plugins: [
        react({
            babel: {
                plugins: [
                    [
                        "babel-plugin-react-compiler",
                        {
                            /* options */
                        },
                    ],
                ],
            },
        }),
    ],
});
```

Add the ESLint plugin:

```js
// eslint.config.mjs
import reactCompiler from "eslint-plugin-react-compiler";

export default [
    // ...
    {
        plugins: { "react-compiler": reactCompiler },
        rules: { "react-compiler/react-compiler": "error" },
    },
];
```

The plugin flags components the Compiler cannot optimize (usually because of dynamic property access, mutation patterns,
or Rules-of-Hooks violations). Fix the bailout reason or accept that specific component as un-optimized.

### Incremental adoption with `"use memo"`

In a codebase where you cannot enable the Compiler globally yet, opt in component-by-component:

```tsx
function TodoList({ todos }: TodoListProps) {
    "use memo";
    const sorted = todos.slice().sort((a, b) => a.dueAt.localeCompare(b.dueAt));
    return sorted.map((t) => <TodoItem key={t.id} todo={t} />);
}
```

The directive applies to the function it appears in (component or custom hook). Pair with
`compilationMode: "annotation"` in the babel config so only opted-in components are compiled.

### When manual memoization still earns its keep

1. **Referential identity is part of a third-party contract.** A virtualizer, drag-and-drop library, or an older
   effect's dep-array consumer cares that the value is the same object. Add a comment explaining why.
2. **The Compiler bailed.** The ESLint plugin tells you. Manual memoization is a stopgap while the bailout reason is
   fixed.
3. **Profiled hot path.** A flame graph shows the function is hot and manual memoization measurably helps.

Strip preemptive `useMemo` / `useCallback` / `React.memo` from new code. The Compiler does it better.

## Suspense + streaming

Suspense boundaries delineate "the part of the tree that can render later". With Server Components, the server streams
resolved chunks as they become available; the client renders fallbacks for unresolved chunks.

Two patterns that change perceived performance dramatically:

### 1. Wrap slow async components in Suspense

```tsx
export default async function PostPage({ params }: Props) {
    const { id } = await params;
    return (
        <article>
            <PostHeader id={id} /> {/* fast */}
            <Suspense fallback={<CommentsSkeleton />}>
                <Comments postId={id} /> {/* slow */}
            </Suspense>
            <Suspense fallback={<RelatedSkeleton />}>
                <RelatedPosts postId={id} /> {/* slow, independent */}
            </Suspense>
        </article>
    );
}
```

The page shell renders first, then each Suspense boundary fills in independently. A slow `Comments` does not delay
`RelatedPosts` if each has its own boundary.

### 2. Stream the shell, then the data

Next.js `loading.tsx` and the framework-level Suspense boundaries automatically stream the static shell while the
dynamic data resolves. No code change beyond placing the boundary correctly.

## Server Components as a performance primitive

Every component that runs on the server ships zero JS to the client. The performance wins:

- **Smaller bundles.** A page that is 80% Server Components ships 80% less code.
- **No client-side data-fetching round-trip.** The data is fetched in the same render pass as the markup.
- **No "loading then content" flash for SSR.** The data is already in the HTML.

Use this aggressively. Push the `"use client"` boundary as deep into the tree as possible. A button that toggles a
popover does not justify making its containing page a client component.

## `<Activity>` for hide-without-unmount

The React 19.2 `<Activity>` component preserves a subtree's state and skips its effects when hidden. Use it instead of
mount/unmount churn for:

- Tab switchers where each tab should remember its state when revisited.
- Modal dialogs that should keep their internal state across opens.
- Off-screen list pages in a virtualized navigation.

```tsx
<Activity mode={visible ? "visible" : "hidden"}>
    <ExpensiveTab />
</Activity>
```

The hidden tree is not unmounted, so state, scroll position, and form inputs all survive. When visibility returns, no
re-mount or re-fetch happens.

## Code splitting

`React.lazy()` + `Suspense` lazy-loads a component as a separate chunk:

```tsx
import { lazy, Suspense } from "react";

const PostEditor = lazy(() => import("./post-editor.js"));

function App() {
    return (
        <Suspense fallback={<EditorSkeleton />}>
            <PostEditor />
        </Suspense>
    );
}
```

In RSC frameworks (Next.js, TanStack Start, React Router 7 in framework mode), route-level code splitting is automatic.
Per-component `lazy()` is for inside-a-route splits — heavyweight editors, dialogs, rich data viewers that are not
needed on first paint.

## Virtualization

For lists with > ~100 visible rows, virtualization wins big. TanStack Virtual is the modern choice:

```tsx
import { useVirtualizer } from "@tanstack/react-virtual";

function PostsList({ posts }: { readonly posts: readonly Post[] }) {
    const parentRef = useRef<HTMLDivElement | null>(null);
    const virtualizer = useVirtualizer({
        count: posts.length,
        getScrollElement: () => parentRef.current,
        estimateSize: () => 100,
        overscan: 5,
    });
    return (
        <div ref={parentRef} className="h-[600px] overflow-auto">
            <div
                style={{
                    height: virtualizer.getTotalSize(),
                    position: "relative",
                }}
            >
                {virtualizer.getVirtualItems().map((item) => (
                    <div
                        key={item.key}
                        style={{
                            position: "absolute",
                            top: 0,
                            transform: `translateY(${item.start}px)`,
                            width: "100%",
                        }}
                    >
                        <PostCard post={posts[item.index]!} />
                    </div>
                ))}
            </div>
        </div>
    );
}
```

Virtualization renders only the visible window. The component cost stays roughly constant as the list grows.

## Concurrent rendering and `useDeferredValue`

When an expensive UI must update in response to a fast-changing input (search-as-you-type, filter sliders),
`useDeferredValue` lets React keep the input responsive while deferring the expensive render:

```tsx
function Search({ query }: { readonly query: string }) {
    const deferredQuery = useDeferredValue(query);
    const results = expensiveFilter(deferredQuery);
    return <Results items={results} />;
}
```

`startTransition` is the imperative version, for marking state updates as non-urgent:

```tsx
import { startTransition } from "react";

function onChange(value: string) {
    setInput(value); // urgent — keep input responsive
    startTransition(() => setQuery(value)); // non-urgent — can be deferred
}
```

Both let React keep the high-priority updates (input, hover) responsive while batching the expensive ones.

## Image performance

In Next.js, use `<Image>` for automatic responsive sizing, lazy loading, format negotiation (AVIF/WebP), and blur
placeholders:

```tsx
import Image from "next/image";

<Image src="/posts/hero.jpg" alt="Cover" width={1200} height={630} priority />;
```

Outside Next, the same primitives are available manually — set `loading="lazy"`, provide an `srcset`, use `<picture>`
for format negotiation.

`priority` for above-the-fold images that should not be lazy-loaded. `placeholder="blur"` for the LQIP pattern.

## Bundle size discipline

- **Tree-shake unused exports.** ESM, named imports, no side-effectful module top levels. Set `"sideEffects": false` in
  `package.json` (or list the side-effect files explicitly).
- **Watch dynamic imports.** `import("./" + name)` cannot be tree-shaken; use a static map of `() => import("./a.js")` /
  `() => import("./b.js")` instead.
- **Audit dependency size.** `npx -y depcheck` and `npx -y source-map-explorer dist/**/*.js` find heavy or unused
  imports. Lodash imports without `lodash-es` / per-function imports are a common culprit.
- **Prefer the platform.** Browser-native `Intl`, `Date`, `crypto.randomUUID`, `structuredClone`, `URL`,
  `URLSearchParams` replace many old utility deps.

## Measuring before optimizing

```ts
import { Profiler } from "react";

function Onboarding() {
  return (
    <Profiler id="onboarding" onRender={(id, phase, actualDuration) => {
      console.log({ id, phase, actualDuration });
    }}>
      <OnboardingFlow />
    </Profiler>
  );
}
```

In production, send these timings to your telemetry. Track:

- **Time to first byte** (server response).
- **Time to first contentful paint** (when the browser paints anything).
- **Time to interactive** (when handlers are wired).
- **INP (Interaction to Next Paint)** — the Core Web Vital for click responsiveness.
- **Cumulative Layout Shift** — content jumping during load.

Optimize the slowest layer. A 200ms server hop matters more than 5ms of memo savings.

## What not to micro-optimize

- Inline arrow function props (the Compiler handles their identity).
- Wrapping every component in `React.memo`.
- Splitting a component into 12 sub-components purely "for performance".
- Premature `useCallback` on every handler.

The biggest performance wins in real React codebases:

1. **Fetching data on the server (Server Components, loaders) instead of in a client `useEffect`.**
2. **Suspense boundaries that allow the shell to render while data loads.**
3. **Right-sizing the client bundle** (Server Components, code splitting, dependency audit).
4. **Virtualization** for long lists.
5. **Pagination / infinite scroll** instead of "fetch everything".

Below those, every micro-tweak is at most a few percent and easily regresses.

## Common mistakes

| Mistake                                                       | Fix                                                             |
| ------------------------------------------------------------- | --------------------------------------------------------------- |
| `useMemo` / `useCallback` on everything                       | Trust the Compiler                                              |
| `React.memo` to "prevent re-renders"                          | Profile first; almost never needed with the Compiler            |
| Client-side `useEffect` fetch                                 | Server Component / TanStack Query loader                        |
| Single Suspense boundary at the root                          | Multiple, scoped to slow subtrees                               |
| Mount/unmount churn for tabs                                  | `<Activity>`                                                    |
| `import * as _ from "lodash"`                                 | Per-function imports from `lodash-es`, or platform alternatives |
| Shipping a 200KB markdown library for a single blog post page | Server-render the markdown                                      |
| Inline arrow functions blamed for re-renders                  | Compiler era — not the bottleneck                               |
| Big images without `width`/`height`                           | Always provide dimensions to avoid CLS                          |
| Animating layout properties (`top`, `left`)                   | Animate `transform` for compositor-only work                    |
