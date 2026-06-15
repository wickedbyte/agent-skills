# Project Structure & Separation of Concerns

How to organize a Next.js 16 App Router project so it stays maintainable as it grows. The guiding principle is \*
\*colocation first, lift to shared only when reuse is real\*\*.

## Contents

- Top-level layout
- The `app/` directory and routing files
- Colocation and private folders
- Route groups
- Where each kind of code lives (separation of concerns)
- Feature-oriented organization for larger apps
- Naming conventions
- Environment variables and server-only code

## Top-level layout

A typical TypeScript-first project scaffolded by `create-next-app` and grown sensibly:

```
my-app/
├─ app/                      # Routing + route-specific UI (App Router)
│  ├─ layout.tsx             # Root layout (required)
│  ├─ page.tsx               # Home route
│  ├─ globals.css
│  ├─ proxy.ts               # (optional) request interception, formerly middleware.ts
│  └─ (marketing)/ ...       # route groups, feature route trees
├─ components/               # Genuinely shared, reusable UI (cross-route)
│  ├─ ui/                    # Primitives (Button, Input) — often shadcn/ui
│  └─ ...
├─ lib/                      # Non-UI logic: data access, clients, helpers
│  ├─ db.ts                  # DB client singleton
│  ├─ auth.ts                # auth config/helpers
│  └─ utils.ts
├─ server/                   # (optional) explicit server-only modules/services
│  └─ services/
├─ hooks/                    # Shared client hooks (use* )
├─ types/                    # Shared TS types/interfaces
├─ public/                   # Static assets served as-is
├─ tests/ or e2e/            # Playwright E2E specs (unit tests colocate)
├─ next.config.ts
├─ tsconfig.json
├─ vitest.config.ts
├─ playwright.config.ts
└─ package.json
```

`src/` is optional: if you prefer, put `app/`, `components/`, `lib/`, etc. under `src/`. Pick one and be consistent.
Everything below applies identically.

## The `app/` directory and routing files

Routing is file-system based. Folders define URL segments; specific files define behavior:

- `page.tsx` — the route's UI (makes the segment publicly routable).
- `layout.tsx` — shared, persistent UI wrapping a segment and its children. The root `app/layout.tsx` is required and
  must render `<html>` and `<body>`.
- `template.tsx` — like a layout but remounts on navigation (fresh state per nav).
- `loading.tsx` — Suspense fallback for the segment (enables streaming).
- `error.tsx` — error boundary (must be a Client Component).
- `not-found.tsx` — UI for `notFound()` and unmatched routes.
- `route.ts` — a Route Handler (HTTP endpoint); cannot coexist with `page.tsx` in the same segment.
- `default.tsx` — required fallback for parallel route slots (v16: builds fail without it).

A file in `app/` is **not** routable unless it's one of these special files — so you can safely colocate other files (
components, tests) in route folders.

## Colocation and private folders

Keep route-specific code next to the route that uses it:

```
app/dashboard/
├─ page.tsx
├─ loading.tsx
├─ error.tsx
├─ _components/            # private folder — never a route segment
│  ├─ revenue-chart.tsx
│  └─ revenue-chart.test.tsx
├─ _lib/
│  └─ get-revenue.ts       # data access used only by this route
└─ dashboard.module.css
```

- A folder prefixed with `_` (e.g. `_components`, `_lib`) is a **private folder**: it and its children are opted out of
  routing. Use these to colocate without risking accidental routes or future-convention collisions.
- Colocate unit tests (`*.test.tsx`) beside the code they test.
- Only promote a component to top-level `components/` when it's used by **more than one** route or feature.

## Route groups

Wrap a folder name in parentheses to organize routes **without** affecting the URL:

```
app/
├─ (marketing)/
│  ├─ layout.tsx          # marketing-only layout
│  ├─ page.tsx            # → /
│  └─ pricing/page.tsx    # → /pricing
└─ (app)/
   ├─ layout.tsx          # authenticated app layout
   └─ dashboard/page.tsx  # → /dashboard
```

Use route groups to (a) apply different layouts to different sections, (b) group related routes, and (c) opt segments
into separate layout hierarchies. The group name never appears in the URL.

## Where each kind of code lives (separation of concerns)

| Concern                    | Lives in                                          | Notes                                                                                                    |
| -------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Routing & page composition | `app/**/page.tsx`, `layout.tsx`                   | Thin — compose components and call data-access functions; avoid heavy logic here.                        |
| Reusable UI                | `components/` (`components/ui/` for primitives)   | Pure, presentational where possible.                                                                     |
| Route-specific UI          | `app/<route>/_components/`                        | Colocated; not shared.                                                                                   |
| Data access / DB queries   | `lib/` or `server/services/`                      | Plain async functions; reused across components without prop-drilling. Mark with `import 'server-only'`. |
| Mutations                  | Server Actions (`actions.ts` with `'use server'`) | Colocate near the feature, or in `app/<route>/actions.ts`.                                               |
| External HTTP API surface  | `app/api/**/route.ts`                             | Only when an endpoint must be consumed by external/3rd-party clients.                                    |
| Validation schemas         | `lib/validations/` or colocated `schema.ts`       | Zod schemas shared between client and server.                                                            |
| Client hooks               | `hooks/`                                          | `use*` hooks for client components.                                                                      |
| Types                      | `types/` or colocated                             | Domain types/interfaces.                                                                                 |
| Config                     | root (`next.config.ts`, etc.)                     | Use env vars, not `serverRuntimeConfig`.                                                                 |

Key separation rules:

- **Pages orchestrate; they don't implement.** A page fetches via a data-access function and renders components.
  Business logic belongs in `lib`/`server`, not inline in `page.tsx`.
- **Data fetching is colocated with rendering** (fetch where you render), but the _implementation_ of the fetch lives in
  a reusable function so multiple components can call it without prop-drilling. React dedupes identical requests within
  a render.
- **Mutations are Server Actions, reads are Server Components / Route Handlers.** Don't use Server Actions to read data.

## Feature-oriented organization for larger apps

For medium-to-large apps, a hybrid of colocation + feature modules scales best. Group cross-cutting feature code under a
`features/` (or `modules/`) directory while keeping routing in `app/`:

```
features/
└─ billing/
   ├─ components/
   ├─ actions.ts            # 'use server'
   ├─ queries.ts            # 'server-only' data access
   ├─ schema.ts             # Zod
   └─ types.ts
app/(app)/billing/page.tsx  # imports from features/billing
```

This keeps `app/` focused on routing and avoids a bloated global `components/` tree. Choose this when multiple routes
share a feature's logic.

## Naming conventions

- Route folders: lowercase, kebab-case (`user-settings/`).
- Component files: `kebab-case.tsx` or `PascalCase.tsx` — pick one and be consistent (kebab-case is common in modern
  setups).
- Server Action files: `actions.ts`. Data-access: `queries.ts`/`<entity>.ts`. Schemas: `schema.ts`.
- Hooks: `use-thing.ts` exporting `useThing`.
- Dynamic segments: `[id]`, catch-all `[...slug]`, optional catch-all `[[...slug]]`.

## Environment variables and server-only code

- Server secrets: unprefixed env vars (`DATABASE_URL`), read only in server code.
- Public, non-sensitive config: `NEXT_PUBLIC_*` (inlined into the client bundle — never put secrets here).
- `serverRuntimeConfig` / `publicRuntimeConfig` are **removed** in v16; use `.env` files.
- Add `import 'server-only'` at the top of modules that must never be bundled into client code (DB clients, secret-using
  helpers). It throws at build time if imported from a Client Component, giving you a hard safety boundary.
- Mirror, use `import 'client-only'` for modules that must only run in the browser.
