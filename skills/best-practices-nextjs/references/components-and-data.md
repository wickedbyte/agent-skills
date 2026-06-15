# Server & Client Components + Data Fetching

How to draw the Server/Client boundary correctly and fetch data idiomatically in Next.js 16.

## Contents

- The mental model
- When to use Client Components
- Drawing the `"use client"` boundary
- Composition patterns (passing server content into client components)
- Data fetching: where and how
- Parallel vs sequential fetching
- Streaming with Suspense, `loading.tsx`, and `error.tsx`
- Passing data from server to client
- Common mistakes

## The mental model

Every component under `app/` is a **React Server Component (RSC)** by default. RSCs run only on the server: they can be
`async`, directly access databases/filesystems/secrets, and send zero JavaScript for themselves to the client. The
question is no longer "should this be SSR'd?" but **"does this component need the browser?"**

A Client Component (`"use client"` at the top of the file) is shipped to and hydrated in the browser. Everything it
imports becomes part of the client bundle. So the boundary placement directly controls bundle size.

## When to use Client Components

Add `"use client"` only when the component needs at least one of:

- Event handlers (`onClick`, `onChange`, `onSubmit`).
- State or lifecycle (`useState`, `useReducer`, `useEffect`, `useRef` for DOM).
- Browser-only APIs (`window`, `localStorage`, `IntersectionObserver`, `navigator`).
- Client-only libraries (most animation, charting-with-interaction, map libraries).
- React Context providers/consumers that rely on client state.
- Hooks like `useActionState`, `useFormStatus`, `useRouter`, `usePathname`, `useSearchParams`.

If none of these apply, keep it a Server Component.

## Drawing the `"use client"` boundary

**Push `"use client"` as far down the tree as possible.** Make small interactive leaves into Client Components; keep
their parents as Server Components.

```tsx
// app/products/[id]/page.tsx — Server Component (async, fetches data)
export default async function ProductPage({
    params,
}: {
    params: Promise<{ id: string }>;
}) {
    const { id } = await params; // params is async in v16
    const product = await getProduct(id); // server-only data access
    return (
        <article>
            <ProductDetails product={product} /> {/* server, static markup */}
            <AddToCartButton productId={product.id} /> {/* client leaf */}
        </article>
    );
}
```

```tsx
// add-to-cart-button.tsx — only the interactive bit is a Client Component
"use client";
import { useState } from "react";
export function AddToCartButton({ productId }: { productId: string }) {
    const [adding, setAdding] = useState(false);
    // ... interactive logic
}
```

Once a file is `"use client"`, every component it imports is also client-side. So a giant top-level `"use client"` page
drags the whole subtree into the bundle — avoid it.

## Composition patterns (server content inside client components)

A Client Component **cannot import** a Server Component, but it **can render Server Components passed as `children` or
props**. Use this to keep server-rendered content out of the client bundle even when it lives visually inside a client
wrapper:

```tsx
// tabs.tsx
"use client";
export function Tabs({ children }: { children: React.ReactNode }) {
    // interactive tab state...
    return <div>{children}</div>;
}
```

```tsx
// page.tsx — Server Component
export default async function Page() {
    return (
        <Tabs>
            <ServerRenderedPanel />{" "}
            {/* stays server-rendered; passed as children */}
        </Tabs>
    );
}
```

Rule of thumb: lift Server Components **up** and pass them **down** as props/children to client wrappers.

## Data fetching: where and how

**Fetch on the server, in Server Components, using plain `async/await`.** This gives direct backend access, keeps
credentials off the client, and avoids client-server waterfalls.

```tsx
async function getPost(slug: string) {
    const res = await fetch(`https://api.example.com/posts/${slug}`);
    if (!res.ok) throw new Error("Failed to load post");
    return res.json();
}
```

Important v16 default: **`fetch` is NOT cached by default** anymore — code is dynamic unless you opt in with
`"use cache"` (see `caching.md`). Set caching intentionally. For a DB/ORM call, wrap it in a data-access function and
add `"use cache"` + `cacheTag`/`cacheLife` when you want it cached.

- **Don't fetch the same data globally and prop-drill it.** Call the same data-access function in each component that
  needs it; React dedupes identical requests within one render pass. For non-`fetch` sources, wrap in React `cache()` to
  dedupe.
- **Reads → Server Components / Route Handlers. Mutations → Server Actions.** Never use a Server Action to fetch read
  data (Server Actions are POST-only and uncacheable).
- **Client-side fetching** (SWR / TanStack Query) is for genuinely client-driven, frequently-refreshing, or
  user-interaction-triggered data — not the default.

## Parallel vs sequential fetching

Avoid accidental waterfalls. Initiate independent requests in parallel:

```tsx
// Parallel — both start immediately
export default async function Page() {
    const artistPromise = getArtist();
    const albumsPromise = getAlbums();
    const [artist, albums] = await Promise.all([artistPromise, albumsPromise]);
    // ...
}
```

Use sequential fetching only when one request genuinely depends on another's result. When a slow request shouldn't block
the rest of the page, isolate it behind its own `<Suspense>` boundary so it streams in independently.

## Streaming with Suspense, loading.tsx, and error.tsx

- A `loading.tsx` in a segment automatically wraps the page in `<Suspense>`, streaming a fallback while the async page
  renders.
- For finer control, wrap slow sub-trees in explicit `<Suspense fallback={...}>` so the fast shell paints immediately
  and slow parts stream in (this is how Partial Prerendering works — see `caching.md`).
- `error.tsx` (a Client Component) catches errors in its segment and provides a `reset()` to retry.

```tsx
export default function Page() {
    return (
        <>
            <Header /> {/* instant */}
            <Suspense fallback={<FeedSkeleton />}>
                <Feed /> {/* streams when ready */}
            </Suspense>
        </>
    );
}
```

## Passing data from server to client

Props passed from a Server Component to a Client Component must be **serializable** (no functions, class instances,
Dates survive but verify). Pass only what the client needs. To trigger server logic from the client, pass a **Server
Action** as a prop (functions marked `'use server'` are the exception — they're passed as references, not serialized
values).

## Common mistakes

- Slapping `"use client"` on a whole page because one button needs interactivity. Extract the button instead.
- Forgetting `params`/`searchParams` are async — destructuring them synchronously errors in v16.
- Using `useEffect` + client `fetch` for data that should be fetched on the server.
- Using a Server Action to read data (it's for mutations).
- Importing a Server Component into a Client Component (won't work — pass as children).
- Assuming `fetch` results are cached (they're not, by default, in v16).
- Putting request-time APIs (`cookies()`, `headers()`, `searchParams`) in the root layout, which opts the entire app
  into dynamic rendering. Scope them and wrap in `<Suspense>`.
