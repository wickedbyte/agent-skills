# React Server Components

The mental model, directives, async components, data fetching, Suspense, streaming, and the "push the client boundary
deep" pattern.

## Mental model

There are two kinds of components, distinguished by where they run:

|                                       | Server Component                            | Client Component            |
| ------------------------------------- | ------------------------------------------- | --------------------------- |
| Where it runs                         | On the server (or at build time)            | In the browser              |
| Default?                              | Yes, in RSC frameworks                      | Opt-in via `"use client"`   |
| Can be `async`?                       | Yes                                         | No (use `use()` + Suspense) |
| Can fetch directly?                   | Yes — db/network call in the component body | No — pass data in via props |
| Can use state / effects / events?     | No                                          | Yes                         |
| Ships to client bundle?               | No                                          | Yes                         |
| Can import client components?         | Yes                                         | Yes                         |
| Can be imported by client components? | Only via slot props (`children`)            | Yes                         |

The rule that determines which one a file is: the **`"use client"` directive at the top of the file**. Without it, the
file is a Server Component (in an RSC framework). With it, the file and everything it imports (transitively) becomes
part of the client bundle.

## The `"use client"` boundary

`"use client"` is a boundary, not a tag-along instruction. The first time React encounters it, it switches from "this is
server-rendered" to "this is client-rendered, hydrated in the browser". Everything imported below that point becomes
client code.

```tsx
// ❌ Top-level "use client" on a page — forfeits Server Components for the whole tree
"use client";

export default function PostPage({ id }: Props) {
    // every child renders on the client; no server data fetch in the component body
}
```

```tsx
// ✅ Server Component page, client island inside
// app/posts/[id]/page.tsx
import { getPost } from "@/data/posts.js";
import { PostInteractions } from "./post-interactions.js";

export default async function PostPage({
    params,
}: {
    params: Promise<{ id: string }>;
}) {
    const { id } = await params;
    const post = await getPost(id);
    return (
        <article>
            <h1>{post.title}</h1>
            <p>{post.body}</p>
            <PostInteractions postId={post.id} initialLikes={post.likes} />
        </article>
    );
}
```

```tsx
// app/posts/[id]/post-interactions.tsx
"use client";

import { useOptimistic } from "react";
import { toggleLike } from "./actions.js";

interface Props {
    readonly postId: string;
    readonly initialLikes: number;
}

export function PostInteractions({ postId, initialLikes }: Props) {
    const [likes, addOptimistic] = useOptimistic(
        initialLikes,
        (state, delta: number) => state + delta,
    );
    return (
        <form
            action={async () => {
                addOptimistic(1);
                await toggleLike(postId);
            }}
        >
            <button>Like ({likes})</button>
        </form>
    );
}
```

The rule: **`"use client"` lives on the smallest component that needs interactivity.** If only one button on a page
needs state, that button is a client component; the rest of the page is server-rendered.

## Async components

Server Components can be `async`. They can `await` data directly in the component body. This is the canonical RSC
data-fetching pattern.

```tsx
async function PostList({ tag }: { readonly tag: string }) {
    const posts = await getPosts({ tag });
    return (
        <ul>
            {posts.map((p) => (
                <li key={p.id}>
                    <Link href={`/posts/${p.id}`}>{p.title}</Link>
                </li>
            ))}
        </ul>
    );
}
```

Client Components cannot be `async`. To consume a promise in a client component, use `use()` + Suspense:

```tsx
"use client";
import { use, Suspense } from "react";

function Post({ postPromise }: { readonly postPromise: Promise<Post> }) {
    const post = use(postPromise);
    return <article>{post.title}</article>;
}

function PostPageClient({ id }: { readonly id: string }) {
    const postPromise = useMemo(() => getPostClient(id), [id]); // stable promise
    return (
        <Suspense fallback={<Spinner />}>
            <Post postPromise={postPromise} />
        </Suspense>
    );
}
```

When possible, fetch in the Server Component and pass the data down. The Suspense + `use()` pattern is for cases where
the client needs to suspend on a value it cannot fetch on the server.

## `params` and `searchParams` are Promises (Next.js 15+)

In Next.js 15 and later (including Next.js 16), route segment props are Promises. `await` them before reading:

```tsx
// app/posts/[id]/page.tsx
interface PageProps {
    readonly params: Promise<{ id: string }>;
    readonly searchParams: Promise<
        Record<string, string | string[] | undefined>
    >;
}

export default async function PostPage({ params, searchParams }: PageProps) {
    const { id } = await params;
    const sp = await searchParams;
    // ...
}
```

This shape lets the framework defer the resolution of params/searchParams until the component actually needs them,
enabling more aggressive partial pre-rendering.

## Server Actions: `"use server"`

A Server Action is a function declared with `"use server"` that the client can invoke (typically from a form action or
an event handler). React handles the RPC plumbing transparently.

```tsx
// app/posts/actions.ts
"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

export async function createPost(
    prev: FormState,
    formData: FormData,
): Promise<FormState> {
    const title = formData.get("title");
    const body = formData.get("body");
    if (typeof title !== "string" || typeof body !== "string") {
        return { error: "Invalid input" };
    }
    const post = await db.posts.insert({ title, body });
    revalidatePath("/posts");
    redirect(`/posts/${post.id}`);
}

export async function toggleLike(postId: string): Promise<void> {
    const user = await getCurrentUser();
    if (user === null) throw new Error("Not authenticated");
    await db.likes.toggle({ userId: user.id, postId });
    revalidatePath(`/posts/${postId}`);
}
```

Patterns:

- **Always validate inputs.** `FormData` values are `FormDataEntryValue | null` — narrow to `string` (and parse further
  with Zod for complex shapes) before using.
- **Always authenticate / authorize.** A Server Action is a callable RPC. Treat it like any API endpoint.
- **Use `revalidatePath` / `revalidateTag` to refresh caches after mutations.** Otherwise the next render sees stale
  data.
- **Use `redirect()` after a successful mutation** to navigate.
- **Return state for the form to display.** Error responses go in the return value, not as thrown exceptions (for
  predictable client handling). Reserve throws for genuinely exceptional conditions.

For Server Actions invoked outside a form (event handlers in a client component), call them like any async function:

```tsx
"use client";
import { toggleLike } from "./actions.js";

export function LikeButton({ postId }: Props) {
    return <button onClick={() => toggleLike(postId)}>Like</button>;
}
```

## Suspense and streaming

Suspense boundaries delineate "the part of the tree that can be rendered later". In RSC frameworks, the server streams
the resolved chunks as data becomes available; the client renders fallback in the meantime.

```tsx
import { Suspense } from "react";

export default async function PostPage({ params }: Props) {
    const { id } = await params;
    return (
        <article>
            <PostHeader id={id} />
            <Suspense fallback={<CommentsSkeleton />}>
                <Comments postId={id} /> {/* slow async server component */}
            </Suspense>
            <Suspense fallback={<RelatedSkeleton />}>
                <RelatedPosts postId={id} /> {/* slow async server component */}
            </Suspense>
        </article>
    );
}
```

Two patterns to remember:

- **Wrap _slow_ async components in Suspense.** Fast ones can render synchronously in the parent.
- **Multiple Suspense boundaries stream independently.** A slow `<Comments>` does not delay a fast `<RelatedPosts>` if
  each has its own boundary.

## Streaming + `loading.tsx`

Next.js (and other RSC frameworks) provide route-segment-level loading UIs via `loading.tsx`. This is just a Suspense
boundary around the route segment:

```tsx
// app/posts/[id]/loading.tsx
export default function Loading() {
    return <PostSkeleton />;
}
```

When the segment's async work suspends, `loading.tsx` renders. When the segment resolves, it replaces the fallback. No
manual `isLoading` prop, no `useEffect` + `fetch`.

## Error boundaries: `error.tsx`

Next.js (and analogous APIs in other RSC frameworks) provide error boundaries via `error.tsx`. The file must be a client
component:

```tsx
// app/posts/[id]/error.tsx
"use client";

interface ErrorPageProps {
    readonly error: Error & { digest?: string };
    readonly reset: () => void;
}

export default function ErrorPage({ error, reset }: ErrorPageProps) {
    return (
        <section>
            <h2>Something went wrong</h2>
            <p>{error.message}</p>
            <button onClick={reset}>Try again</button>
        </section>
    );
}
```

For non-Next-Route error handling, use a regular React error boundary. The `react-error-boundary` package is the
idiomatic third-party option.

## Composition rules

Server Components can render Client Components. Client Components cannot import Server Components, but they can receive
them as `children` (or any other prop holding ReactNode).

```tsx
// ✅ Server Component renders Client Component, passing Server Component as children
// app/layout.tsx (server)
import { Sidebar } from "./sidebar.js"; // client
import { Nav } from "./nav.js"; // server

export default function Layout({ children }: Props) {
    return (
        <>
            <Nav />
            <Sidebar>
                <RecentPosts />{" "}
                {/* server component, passed as children to a client */}
            </Sidebar>
            <main>{children}</main>
        </>
    );
}
```

```tsx
// app/sidebar.tsx
"use client";
import { useState } from "react";

export function Sidebar({ children }: { readonly children: React.ReactNode }) {
    const [open, setOpen] = useState(true);
    return (
        <aside>
            <button onClick={() => setOpen((o) => !o)}>Toggle</button>
            {open && <div>{children}</div>}
        </aside>
    );
}
```

This composition lets you keep server-rendered data inside a client-interactive wrapper. The data fetch never crosses to
the client.

## What server components can and can't do

| Capability                                            | Server Component | Client Component          |
| ----------------------------------------------------- | ---------------- | ------------------------- |
| `async/await`                                         | ✅               | ❌ (use `use()`)          |
| Direct DB / file system access                        | ✅               | ❌                        |
| Server-only secrets                                   | ✅               | ❌ (would leak in bundle) |
| `useState`, `useReducer`, `useEffect`, event handlers | ❌               | ✅                        |
| Browser-only APIs (`window`, `localStorage`)          | ❌               | ✅                        |
| Render imported client components                     | ✅               | ✅                        |
| Render imported server components                     | ✅               | Via `children` only       |
| `onClick`, `onChange`, ...                            | ❌               | ✅                        |

## Common mistakes

| Mistake                                                                                | Fix                                                                        |
| -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `"use client"` at the top of a Page / Layout that mostly renders static markup         | Push it down to the actual interactive island                              |
| Importing a Server Component into a Client Component                                   | Pass it via `children` from a Server Component parent                      |
| Fetching the same data twice (in a Server Component and again in a client `useEffect`) | Fetch in the Server Component, pass as props                               |
| Putting secrets in a component that ends up in the client bundle                       | Move to a Server Component or Server Action; check `import "server-only"`  |
| Server Action without input validation                                                 | Validate with Zod (or equivalent) before touching the database             |
| Server Action without auth check                                                       | Authenticate explicitly; do not rely on the form being on a protected page |
| `params` / `searchParams` read directly without `await` (Next.js 15+)                  | `await` them — they are Promises                                           |
| Slow async work without a Suspense boundary                                            | Wrap in `<Suspense fallback={...}>` for streaming                          |

## `import "server-only"` and `import "client-only"`

These no-op imports cause a build error if the file ends up in the wrong bundle. Use them on modules that _must not_
leak:

```ts
// lib/secrets.ts
import "server-only";

export const API_KEY = process.env.API_KEY!;
```

If a client component accidentally imports this file (directly or transitively), the build fails.

`import "client-only"` is the inverse — useful for browser-API wrappers that must not be evaluated on the server.
