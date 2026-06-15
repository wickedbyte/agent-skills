# Caching & Cache Components (v16)

Next.js 16's caching model is **explicit and opt-in**. This is the biggest conceptual change from earlier versions. Read
this whenever caching, revalidation, freshness, or performance is involved.

## Contents

- The new default: dynamic unless cached
- Enabling Cache Components
- The `"use cache"` directive (and variants)
- `cacheLife` — time-based revalidation
- `cacheTag` + `revalidateTag`/`updateTag` — on-demand invalidation
- `refresh()` — uncached data
- Partial Prerendering (PPR) and the static shell
- `connection()` and when to force dynamic
- Security: private vs shared caches
- Gotchas
- Decision guide

## The new default: dynamic unless cached

In v16, **all dynamic code in any page, layout, or route handler executes at request time by default.** Nothing is
implicitly cached — not `fetch`, not pages. You opt **into** caching with `"use cache"`. This means out of the box the
app behaves like a normal full-stack server app (no surprise stale data), and you add caching deliberately where it
helps.

## Enabling Cache Components

```ts
// next.config.ts
const nextConfig = {
    cacheComponents: true, // (was experimental.dynamicIO / useCache in 15)
};
export default nextConfig;
```

With Cache Components enabled, Next.js prerenders a **static shell** by default and uses Partial Prerendering:
cached/static content is in the shell, dynamic content streams via `<Suspense>`. `experimental.ppr` and
`experimental_ppr` are removed — PPR is now the default behavior under Cache Components.

## The `"use cache"` directive

Add `"use cache"` at the top of a **file**, **component**, or **async function** to cache its output/return value. The
compiler generates the cache key from the function's serializable inputs automatically.

```ts
// Cache a data-access function's return value
import { cacheLife, cacheTag } from "next/cache";

export async function getProducts() {
    "use cache";
    cacheTag("products");
    cacheLife("hours");
    return db.products.findMany();
}
```

```tsx
// Cache a component (and thus its rendered subtree)
async function BlogPosts() {
    "use cache";
    cacheLife("days");
    const posts = await getPosts();
    return <PostList posts={posts} />;
}
```

To prerender an **entire route**, add `"use cache"` to the top of **both** `layout.tsx` and `page.tsx` — each is cached
independently as a separate entry point.

Rules:

- A `"use cache"` function **must be async**.
- Inputs must be serializable; return values must be serializable.
- You cannot read request-time data (`cookies()`, `headers()`, `searchParams`) inside a plain `"use cache"` scope — that
  data is request-specific. Use `"use cache: private"` or a `"use cache: remote"` keyed by the relevant value instead.

### Variants

- `"use cache"` — standard shared cache (same output for all users). **Never** use for user-specific data.
- `"use cache: private"` — per-user cache for personalized content. Use this for anything tied to the current
  user/session so data doesn't leak across users.
- `"use cache: remote"` — shared remote cache (survives across serverless instances). Good for expensive DB queries
  keyed by a small set of values (e.g. price by currency). Can be used at request time when keyed correctly.

## `cacheLife` — time-based revalidation

Set how long a cache entry is fresh. Use built-in profiles or a custom object:

```ts
cacheLife("seconds");
cacheLife("minutes");
cacheLife("hours");
cacheLife("days");
cacheLife("weeks");
cacheLife("max");
// custom:
cacheLife({ stale: 300, revalidate: 900, expire: 3600 }); // seconds
```

- Call `cacheLife` **once per execution path**. In `if/else` branches you may call it in each branch as long as only one
  runs — useful when different outcomes need different durations (e.g. cache a missing/draft item briefly, a published
  item for days).
- Define reusable custom profiles in `next.config.ts` under `cacheLife`.

## `cacheTag` + invalidation

Tag a cache entry so you can invalidate it later:

```ts
export async function getProduct(id: string) {
    "use cache";
    cacheTag(`product-${id}`, "products"); // up to 128 tags/entry, 256 chars each
    return db.products.find(id);
}
```

Invalidate from a Server Action or Route Handler. **v16 changed the APIs:**

- **`revalidateTag(tag, profile)`** — invalidate tagged entries with **stale-while-revalidate**. The second argument (a
  `cacheLife` profile) is now **required**; `'max'` is recommended for most cases. Users get cached data immediately
  while it revalidates in the background. Best for content tolerant of eventual consistency.
    ```ts
    revalidateTag("products", "max");
    ```
- **`updateTag(tag)`** — **Server-Actions-only**, **read-your-writes**: expires and immediately re-reads fresh data in
  the same request, so the user sees their change instantly. Use after the user mutates their own data (forms,
  settings).
    ```ts
    "use server";
    import { updateTag } from "next/cache";
    export async function saveProfile(id: string, data: Profile) {
        await db.users.update(id, data);
        updateTag(`user-${id}`); // user sees update immediately
    }
    ```
- The single-argument `revalidateTag('tag')` form is **deprecated** — migrate to the two-argument form or `updateTag`.

## `refresh()` — uncached data

**`refresh()`** (Server-Actions-only) refreshes **uncached** data displayed elsewhere on the page without touching the
cache — e.g. a live notification count after marking one read. Complementary to client `router.refresh()`.

```ts
"use server";
import { refresh } from "next/cache";
export async function markRead(id: string) {
    await db.notifications.markRead(id);
    refresh(); // re-render uncached parts (e.g. header count)
}
```

## Partial Prerendering (PPR) and the static shell

Under Cache Components, a single page combines: (1) **static content** prerendered into the shell, (2) **cached dynamic
content** (`"use cache"`) included in the shell, and (3) **runtime dynamic content** that streams via `<Suspense>`.
Place `<Suspense>` boundaries **close to** the dynamic content so the rest of the page stays in the fast static shell.

```tsx
export default function BlogPage() {
    return (
        <>
            <header>{/* static */}</header>
            <BlogPosts /> {/* cached dynamic, in shell */}
            <Suspense fallback={<Spinner />}>
                <UserPreferences /> {/* request-time, streams */}
            </Suspense>
        </>
    );
}
```

## `connection()` and forcing dynamic

`connection()` (from `next/server`) opts the rendering point into request time. **It's often an anti-pattern**: using it
high in the tree opts the entire route into dynamic rendering and loses caching benefits. Only use it when the whole
page must be dynamic (e.g. CSP nonces, fully user-specific page with nothing cacheable). For partial dynamic content,
prefer `<Suspense>` + `"use cache"`.

## Security: private vs shared caches

Cache Components don't know your auth model. **If you cache user-specific data with shared `"use cache"`, it can be
served to other users.** Always:

- Use `"use cache: private"` for personalized/authenticated content.
- Never tag-cache one user's data under a shared tag.
- Verify cached functions don't capture request-scoped identity implicitly.

## Gotchas

- `"use cache"` functions must be **async**.
- Async callbacks inside `.map()` don't work the way you might expect inside cached scopes — cache the data function,
  not an inline async map callback.
- Don't read `cookies()`/`headers()`/`searchParams` inside shared `"use cache"`.
- `revalidateTag` without a profile is deprecated — always pass the profile.
- Migrating a 15→16 app: with caching now opt-in, previously-fast static pages may render dynamically until you add
  `"use cache"`. Migration order: enable `cacheComponents`, add `"use cache"` to clearly-static pages (landing, blog,
  docs, pricing) first, then set `cacheLife` profiles, then wire `cacheTag`/`revalidateTag` for mutations.

## Decision guide

- Static, rarely-changing page (marketing, docs, blog post) → `"use cache"` on layout+page, `cacheLife('days'|'max')`.
- Expensive shared query (catalog, prices by currency) → `"use cache"` / `"use cache: remote"` + `cacheTag` +
  `cacheLife`.
- Per-user content → `"use cache: private"` or leave dynamic behind `<Suspense>`.
- User just mutated their own data and must see it → `updateTag` in the Server Action.
- Content tolerant of slight staleness, invalidated by a webhook/admin action → `revalidateTag(tag, 'max')`.
- Uncached live widget needs refresh after an action → `refresh()`.
- Whole page must be dynamic, nothing cacheable → leave dynamic (default); use `connection()` only if you must force it.
