---
name: best-practices-nextjs
description: >-
    Write, structure, and test production-grade Next.js 16 (App Router) applications using current best practices. Use
    this skill whenever the user is building, scaffolding, refactoring, reviewing, or debugging a Next.js app —
    including questions about project layout, Server vs Client Components, data fetching, Server Actions, Cache 
    Components and the "use cache" directive, routing, proxy.ts (formerly middleware), caching/revalidation APIs, route
    handlers, metadata/SEO, performance, or testing with Vitest/Playwright/RTL. Trigger it even when the user just says
    "Next.js", "App Router", "RSC", "next.config", or names a Next file (page.tsx, layout.tsx, route.ts, proxy.ts)
    without explicitly asking for "best practices." Prefer this skill over generic React knowledge for anything that
    touches the Next.js framework, since Next.js 16 changed many defaults (async params, opt-in caching, Turbopack,
    proxy.ts) that pre-2025 knowledge gets wrong.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# Best Practices Nextjs

Write idiomatic, well-structured, well-tested Next.js 16 applications using the App Router. This skill encodes the
conventions, defaults, and patterns that are current as of mid-2026 — many of which **invert** older Next.js advice.
Read the relevant reference file before writing nontrivial code; the references contain the detailed patterns, code, and
gotchas.

## The single most important thing to internalize

Next.js 16 changed enough defaults that training-data instincts are frequently **wrong**. Before writing code, check
these against your assumptions:

- **Everything is dynamic by default.** Caching is now **opt-in** via the `"use cache"` directive (Cache Components).
  The old implicit "pages are static unless you opt out" model is gone. Do not assume `fetch` is cached.
- **`params`, `searchParams`, `cookies()`, `headers()`, `draftMode()` are all async.** You must `await` them.
  Synchronous access is removed and will error.
- **`middleware.ts` is now `proxy.ts`** with an exported `proxy` function, running on Node.js. `middleware.ts` is
  deprecated.
- **Turbopack is the default bundler.** No config needed. `next lint` is removed — use ESLint/Biome directly.
- **Server Components are the default.** `"use client"` is an opt-in boundary, not a default. Push it as far down the
  tree as possible.
- **`next/image` defaults tightened**: `qualities` defaults to `[75]`, local IPs blocked, redirects capped,
  `images.domains` deprecated in favor of `remotePatterns`.

When in doubt about whether something changed, read `references/migration-and-defaults.md` rather than trusting memory.

## Workflow for any Next.js task

1. **Identify the task type** and read the matching reference file(s) below before writing code. Don't skip this — the
   references contain the exact current APIs.
2. **Default to Server Components.** Only reach for `"use client"` when the component needs interactivity (event
   handlers), browser-only APIs, state/effects, or client-only libraries. Keep client components small and at the
   leaves.
3. **Fetch data on the server** in Server Components or shared data-access functions. Mutate with **Server Actions**.
   Use Route Handlers only for public/external API surface.
4. **Make caching explicit.** Code is dynamic unless you add `"use cache"`. Tag cache entries and revalidate them in
   Server Actions.
5. **Validate and authorize every Server Action and Route Handler** as if it were a public HTTP endpoint — because it
   is.
6. **Write tests at the right layer.** Vitest + React Testing Library for synchronous components, Server Actions (as
   plain functions), schemas, and utilities. Playwright for async Server Components, auth flows, and full user journeys.
   Async Server Components cannot be unit-tested in jsdom yet.
7. **Type everything.** TypeScript is the default; use typed routes, `satisfies`, and async-aware prop types.

## Reference files — read the one(s) that match the task

| Read this                                 | When the task involves                                                                                                                                                                                  |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `references/project-structure.md`         | Folder layout, where code goes, colocation, route groups, private folders, `app/` vs `lib/` vs feature folders, separation of concerns, naming. **Read first when scaffolding a new project.**          |
| `references/components-and-data.md`       | Server vs Client Components, the `"use client"` boundary, composition patterns, data fetching (parallel/sequential, streaming, `<Suspense>`), `loading.tsx`/`error.tsx`, passing server data to client. |
| `references/caching.md`                   | Cache Components, `"use cache"` / `"use cache: private"` / `"use cache: remote"`, `cacheLife`, `cacheTag`, `revalidateTag`, `updateTag`, `refresh`, PPR, `connection()`, when NOT to cache.             |
| `references/server-actions-and-routes.md` | Server Actions (forms, mutations, `useActionState`, `useFormStatus`), Zod validation, security/authorization, Route Handlers (`route.ts`), when to use which, `proxy.ts`.                               |
| `references/routing-and-rendering.md`     | File conventions, dynamic/catch-all routes, layouts, templates, parallel & intercepting routes, metadata/SEO, `generateStaticParams`, error/not-found handling, redirects.                              |
| `references/testing.md`                   | Full testing stack and setup (Vitest, RTL, Playwright, MSW), what to test at each layer, how to test Server Actions/components/routes, what NOT to test, CI gating.                                     |
| `references/migration-and-defaults.md`    | Every changed default and breaking change in v16, `next.config.ts` reference, codemods, version/runtime requirements, deprecations. **Read when upgrading or when behavior surprises you.**             |

If a task spans several areas (e.g. "build a product page with a form"), read each relevant reference; they're written
to compose.

## Idiomatic baseline (applies to almost everything)

These hold across nearly all Next.js 16 code, so keep them in mind even without opening a reference:

- **Colocate** route-specific components, tests, and styles inside the route folder; lift only genuinely shared code to
  `components/`, `lib/`, `hooks/`. Use private folders (`_components`) for non-routable colocation.
- **A page or layout that awaits `params`/`searchParams`/`cookies()` is async.** Type its props accordingly (
  `params: Promise<{ id: string }>`).
- **Add `loading.tsx`, `error.tsx`, and (where relevant) `not-found.tsx`** to route segments for a polished UX and
  proper streaming.
- **Server Actions return typed result objects** (`{ ok, data }` / `{ ok: false, fieldErrors }`) rather than throwing
  for expected validation failures; throw only for truly exceptional cases handled by an error boundary.
- **Never put secrets in `NEXT_PUBLIC_*`** env vars — those are inlined into the client bundle. Server-only secrets stay
  unprefixed and are accessed only in server code; add `import 'server-only'` to modules that must never reach the
  client.
- **Prefer `next/link` and `next/image`**; set `revalidate`/cache semantics intentionally rather than relying on
  unverified defaults.
- **Run the same lint/typecheck/test gate locally that CI runs.** `next build` no longer lints, so wire ESLint and
  `tsc --noEmit` explicitly.

## A note on quality

The goal is code that a senior Next.js engineer in 2026 would approve without rewrites: correct boundaries, explicit
caching, secure server code, accessible UI, and tests that exercise real behavior rather than implementation details.
When trade-offs exist (e.g. caching vs freshness, Server Action vs Route Handler), state the trade-off briefly and pick
the option the references recommend for the described use case.
