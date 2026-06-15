# Routing, Rendering & Metadata

File conventions, dynamic routing, layouts, advanced routing patterns, metadata/SEO, and rendering behavior in the App
Router.

## Contents

- File conventions recap
- Dynamic, catch-all, and optional segments
- `params` and `searchParams` are async
- Layouts vs templates
- `generateStaticParams`
- Parallel routes & intercepting routes
- Error, not-found, and redirects
- Metadata & SEO
- Rendering behavior (static shell, dynamic, streaming)
- Navigation

## File conventions recap

Within a route segment folder:

| File               | Purpose                                                           |
| ------------------ | ----------------------------------------------------------------- |
| `page.tsx`         | Route UI (makes segment routable)                                 |
| `layout.tsx`       | Shared, persistent wrapper (root must render `<html>`/`<body>`)   |
| `template.tsx`     | Like layout but remounts per navigation                           |
| `loading.tsx`      | Suspense fallback (enables streaming)                             |
| `error.tsx`        | Error boundary (Client Component; gets `error`, `reset`)          |
| `global-error.tsx` | Root-level error boundary (replaces root layout)                  |
| `not-found.tsx`    | UI for `notFound()` / unmatched                                   |
| `route.ts`         | HTTP endpoint (mutually exclusive with `page.tsx`)                |
| `default.tsx`      | Required fallback for parallel slots (v16 fails build without it) |

## Dynamic, catch-all, and optional segments

- `[id]` → single dynamic segment (`/posts/[id]`).
- `[...slug]` → catch-all (`/docs/a/b/c` → `slug: ['a','b','c']`).
- `[[...slug]]` → optional catch-all (also matches the parent route with no segment).

## `params` and `searchParams` are async

**In v16 these are Promises and must be awaited.** Type props accordingly:

```tsx
export default async function Page({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>;
    searchParams: Promise<{ [key: string]: string | string[] | undefined }>;
}) {
    const { id } = await params;
    const { q } = await searchParams;
    // ...
}
```

The same is true for `cookies()`, `headers()`, `draftMode()` (all async now) and for `params` in Route Handlers,
metadata functions, and `generateImageMetadata`. Using `searchParams` or request APIs opts the route into request-time
rendering — scope them and wrap in `<Suspense>` to keep the rest static.

## Layouts vs templates

- **Layouts persist** across navigations within their segment — state and DOM are preserved, they don't re-render on
  child navigation. Use for nav bars, sidebars, shells.
- **Templates remount** on every navigation — fresh state, re-run effects. Use when you need enter animations or
  per-navigation resets.
- Layouts nest: the root layout wraps everything; segment layouts wrap their subtree. Layouts receive `children` (and
  parallel-route slots as named props).

## `generateStaticParams`

Pre-render dynamic routes at build time by enumerating params:

```tsx
export async function generateStaticParams() {
    const posts = await getAllPostSlugs();
    return posts.map((slug) => ({ slug }));
}
```

Combine with `"use cache"`/`cacheLife` for incremental-style revalidation. Params not returned can still be rendered on
demand depending on your config.

## Parallel routes & intercepting routes

- **Parallel routes** (`@slot` folders) render multiple pages in the same layout simultaneously — e.g. a dashboard with
  `@team` and `@analytics` slots, or modals. **v16: every slot needs an explicit `default.tsx`** (return `null` or call
  `notFound()` for the old behavior) or the build fails.
- **Intercepting routes** (`(.)`, `(..)`, `(...)` prefixes) load a route within the current layout — classic use is
  showing a photo/modal over the current page while keeping a shareable URL. Pair with parallel routes for modal
  patterns.

## Error, not-found, and redirects

- Throw `notFound()` (from `next/navigation`) to render the nearest `not-found.tsx`.
- `error.tsx` catches render/data errors in its segment; provide a retry via `reset()`. It must be a Client Component.
- Use `redirect()` / `permanentRedirect()` (from `next/navigation`) in Server Components/Actions; in `proxy.ts` use
  `NextResponse.redirect`.

## Metadata & SEO

Export static `metadata` or a dynamic `generateMetadata` from a `layout`/`page`:

```tsx
import type { Metadata } from "next";

export const metadata: Metadata = {
    title: "Products",
    description: "Browse our catalog",
};

// or dynamic (params is async in v16):
export async function generateMetadata({
    params,
}: {
    params: Promise<{ id: string }>;
}): Promise<Metadata> {
    const { id } = await params;
    const product = await getProduct(id);
    return { title: product.name, openGraph: { images: [product.image] } };
}
```

- Use the Metadata API for `<title>`, description, Open Graph, Twitter, canonical, robots.
- File-based metadata: `favicon.ico`, `opengraph-image.tsx`, `sitemap.ts`, `robots.ts`, `manifest.ts`. In v16, metadata
  image route `params` is async and `generateImageMetadata`'s `id` is a `Promise<string>`.
- Set `metadataBase` for absolute OG URLs.

## Rendering behavior (static shell, dynamic, streaming)

With Cache Components (see `caching.md`), each route produces a **static shell** (prerendered HTML + RSC payload) plus
streamed dynamic content. Mentally classify each part of a page as: static (in shell), cached-dynamic (`"use cache"`, in
shell), or runtime-dynamic (streams via `<Suspense>`). Keep request-time APIs out of the root layout to avoid forcing
the whole app dynamic.

## Navigation

- Use `<Link href>` for client-side navigation; v16 improves prefetching (layout deduplication, incremental,
  viewport-aware) automatically — no code changes needed.
- Programmatic navigation: `useRouter()` (`router.push`, `router.replace`, `router.refresh`) in Client Components.
- Read current location with `usePathname`, `useSearchParams`, `useParams` (Client Components).
