# Routing

Three modern options for React in 2026: **Next.js App Router**, **React Router 7**, and **TanStack Router**. Pick one
per app and follow its idioms.

## How to choose

| You want                                                                                                                                   | Pick                                                                       |
| ------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| Full-stack with RSC, Server Actions, edge runtime, deployment to Vercel-style platforms                                                    | **Next.js App Router** (Next 16)                                           |
| Multi-strategy router that works as a library inside an existing app OR as a framework with loaders/actions; large existing Remix codebase | **React Router 7** (the merge of Remix + React Router v6)                  |
| The strongest TypeScript story (typed params, search, links), file-based routing, deep TanStack Query integration                          | **TanStack Router** (1.114+), often with **TanStack Start** for full-stack |

Mixing two routers in one app is a mistake.

## Next.js App Router (Next 16)

File-based routing under `app/`. Server Components by default; `params` and `searchParams` are Promises.

### Route structure

```
app/
├── layout.tsx           # root layout (server component)
├── page.tsx             # / (server component)
├── posts/
│   ├── page.tsx         # /posts
│   ├── loading.tsx      # Suspense fallback
│   ├── error.tsx        # error boundary (client component)
│   └── [id]/
│       ├── page.tsx     # /posts/:id
│       ├── loading.tsx
│       └── opengraph-image.tsx
└── (marketing)/         # route group — no URL segment
    ├── about/page.tsx
    └── contact/page.tsx
```

### A page

```tsx
// app/posts/[id]/page.tsx
import { notFound } from "next/navigation";
import { getPost } from "@/data/posts.js";

interface Props {
    readonly params: Promise<{ id: string }>;
    readonly searchParams: Promise<
        Record<string, string | string[] | undefined>
    >;
}

export default async function PostPage({ params, searchParams }: Props) {
    const { id } = await params;
    const post = await getPost(id);
    if (post === null) notFound();
    return (
        <article>
            <h1>{post.title}</h1>
            <p>{post.body}</p>
        </article>
    );
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
    const { id } = await params;
    const post = await getPost(id);
    if (post === null) return { title: "Not found" };
    return { title: post.title, description: post.excerpt };
}
```

### Layouts

Layouts wrap pages and persist across navigations within their segment:

```tsx
// app/posts/layout.tsx
export default function PostsLayout({
    children,
}: {
    readonly children: React.ReactNode;
}) {
    return (
        <div className="mx-auto max-w-3xl py-8">
            <nav>...</nav>
            {children}
        </div>
    );
}
```

### Navigation

```tsx
// Server / client — declarative
import Link from "next/link";
<Link href="/posts/123" prefetch>
    Post 123
</Link>;

// Client — imperative
("use client");
import { useRouter } from "next/navigation";
const router = useRouter();
router.push("/posts/123");
```

### Search params

Read from props in a Server Component:

```tsx
export default async function Page({ searchParams }: Props) {
    const sp = await searchParams;
    const q = typeof sp.q === "string" ? sp.q : "";
    // ...
}
```

Validate with Zod for type safety:

```ts
import { z } from "zod";
const Search = z.object({
    q: z.string().optional(),
    page: z.coerce.number().int().nonnegative().default(0),
});
```

In Client Components, use `useSearchParams` from `next/navigation`.

### Server Actions

See `references/forms.md` and `references/server-components.md`. Server Actions integrate with `<form action={action}>`
and with `useActionState`.

### Caching (Next 16)

Next 16 introduces fine-grained cache controls. Key directives:

- `"use cache"` at the top of a function or module marks the output as cacheable.
- `cacheLife("hours")` / `cacheTag("posts")` set lifetime and tags.
- `revalidateTag("posts")` invalidates by tag.
- `dynamic = "force-static" | "force-dynamic"` route-segment config opts a route segment in/out of caching.

```ts
// data/posts.ts
"use cache";
import { cacheLife, cacheTag } from "next/cache";

export async function getPosts(): Promise<Post[]> {
    cacheLife("hours");
    cacheTag("posts");
    const response = await fetch("https://api.example.com/posts");
    return Posts.parse(await response.json());
}
```

## React Router 7

The merger of Remix and React Router v6. Works two ways:

- **Library mode** — drop-in router for an existing client-side app.
- **Framework mode** — file-based routes, loaders, actions, SSR, similar to Remix v2.

### Framework mode — routes config

```ts
// app/routes.ts
import { type RouteConfig, route, layout } from "@react-router/dev/routes";

export default [
    layout("layouts/root.tsx", [
        route("", "routes/home.tsx"),
        route("posts", "routes/posts.tsx", [route(":id", "routes/post.tsx")]),
    ]),
] satisfies RouteConfig;
```

### Loader + component

```tsx
// app/routes/post.tsx
import type { Route } from "./+types/post";

export async function loader({ params }: Route.LoaderArgs) {
    const post = await getPost(params.id);
    if (post === null) throw new Response("Not Found", { status: 404 });
    return { post };
}

export default function Post({ loaderData }: Route.ComponentProps) {
    const { post } = loaderData;
    return (
        <article>
            <h1>{post.title}</h1>
        </article>
    );
}

export function meta({ data }: Route.MetaArgs) {
    return [{ title: data?.post.title ?? "Not Found" }];
}
```

The `Route` type is generated per route (`./+types/post`) and gives type-safe `params`, `loaderData`, `actionData`, and
meta args.

### Action

```tsx
export async function action({ request, params }: Route.ActionArgs) {
    const formData = await request.formData();
    const title = formData.get("title");
    if (typeof title !== "string") {
        return { error: "Invalid input" };
    }
    await updatePost(params.id, { title });
    return { error: null };
}
```

### Navigation

```tsx
import { Link, useNavigate, useSearchParams } from "react-router";

<Link to={`/posts/${id}`}>Post</Link>
<Link to={{ pathname: "/posts", search: "?tag=react" }}>React posts</Link>

const navigate = useNavigate();
navigate(`/posts/${id}`, { replace: true });

const [searchParams, setSearchParams] = useSearchParams();
```

### Server functions (RSC opt-in)

React Router 7 ships an RSC opt-in. When enabled, route components can be `async` Server Components, and you can use
`"use server"` actions identically to Next.js.

## TanStack Router

The strongest type story. File-based routes generated into a `routeTree.gen.ts` file; the type system knows every
route's params, search shape, and link targets.

### Project setup

```ts
// router.tsx
import { createRouter, RouterProvider } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen";

const router = createRouter({ routeTree });
declare module "@tanstack/react-router" {
  interface Register { router: typeof router }
}

export function AppRouter() { return <RouterProvider router={router} />; }
```

### A route

```tsx
// src/routes/posts.$id.tsx
import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

export const Route = createFileRoute("/posts/$id")({
    params: { parse: z.object({ id: z.string().uuid() }).parse },
    validateSearch: z.object({
        tab: z.enum(["overview", "comments"]).default("overview"),
    }),
    loader: async ({ params }) => {
        return { post: await fetchPost(params.id) };
    },
    component: PostPage,
});

function PostPage() {
    const { post } = Route.useLoaderData();
    const { tab } = Route.useSearch();
    return (
        <article>
            <h1>{post.title}</h1>
            <Tabs value={tab}>...</Tabs>
        </article>
    );
}
```

### Type-safe links

```tsx
import { Link } from "@tanstack/react-router";

<Link to="/posts/$id" params={{ id: post.id }} search={{ tab: "comments" }}>
    Comments
</Link>;
```

`to`, `params`, and `search` are all typed against the route tree. A wrong route, missing param, or invalid search value
fails at compile time.

### TanStack Router + TanStack Query

The pairing is the platform's gold standard. Route loaders prefetch with `queryClient.ensureQueryData`; components
consume with `useSuspenseQuery`:

```tsx
import { queryOptions } from "@tanstack/react-query";

const postQuery = (id: string) =>
    queryOptions({
        queryKey: ["post", id],
        queryFn: () => fetchPost(id),
    });

export const Route = createFileRoute("/posts/$id")({
    loader: ({ params, context: { queryClient } }) =>
        queryClient.ensureQueryData(postQuery(params.id)),
    component: PostPage,
});

function PostPage() {
    const { id } = Route.useParams();
    const { data: post } = useSuspenseQuery(postQuery(id));
    return (
        <article>
            <h1>{post.title}</h1>
        </article>
    );
}
```

The query is fetched in the loader, cached in TanStack Query, and read from `useSuspenseQuery` in the component. No
duplicate fetches.

## Patterns across all routers

### Validate search params at the boundary

Whatever router you use, treat search params as untrusted input:

- TanStack Router: `validateSearch` with a schema.
- React Router 7: read with `useSearchParams`, validate with Zod.
- Next.js: read from `searchParams` prop, validate with Zod.

Inside the app, the parsed shape is a typed domain value. Outside, it is `unknown`.

### Use the typed link / navigate API

A bare `<a href="/posts/123">` triggers a full page navigation. Use the framework's link component:

- TanStack: `<Link to="/posts/$id" params={{ id }} />` (compile-time-checked)
- React Router: `<Link to={`/posts/${id}`} />`
- Next.js: `<Link href={`/posts/${id}`} />`

### Loaders for data, not effects

If your router has loaders (React Router 7, TanStack Router), use them. Loaders run _before_ the component renders,
integrate with caches, support parallel data fetching, and avoid the "fetch in `useEffect` and show a spinner" pattern.

For Next.js App Router, the equivalent is fetching directly in the async Server Component.

### Prefetching on hover / intent

- Next.js: `<Link prefetch />`
- TanStack Router: `<Link preload="intent" />` (also `"viewport"`, `"render"`)
- React Router: `<Link prefetch="intent" />` (framework mode)

Prefetch on hover/focus is a major UX upgrade for free.

## Common mistakes

| Mistake                                                                | Fix                                                                                         |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `<a href>` for internal navigation                                     | Framework's `<Link>`                                                                        |
| Reading `searchParams` without parsing                                 | Zod / Valibot / framework parser                                                            |
| Forgetting to `await params` in Next.js 15+                            | `const { id } = await params;`                                                              |
| Fetching in a `useEffect` instead of a loader / async Server Component | Loaders or RSC                                                                              |
| Mixing two routers                                                     | Pick one                                                                                    |
| Putting transient UI state in route params                             | Local `useState` instead; URL is for _shareable_ state                                      |
| Not validating dynamic route segment shapes                            | `params: { parse: ... }` (TanStack) or guard in the loader                                  |
| Wrapping a whole page in `"use client"` to use `useRouter`             | The router has Server Component equivalents (Next.js: `redirect()`, `revalidatePath`, etc.) |
