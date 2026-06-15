# v16 Defaults, Breaking Changes & Migration

Read this when upgrading from 15, when behavior surprises you, or to confirm a current default before trusting memory.
Everything here reflects Next.js 16 (and 16.1/16.2 minor updates) as of mid-2026.

## Contents

- Version & runtime requirements
- The big behavioral inversions
- `next.config.ts` reference
- Removed features
- Changed defaults
- Deprecations
- Codemods & upgrade path
- 16.1 / 16.2 notable additions

## Version & runtime requirements

| Requirement | v16 minimum                            |
| ----------- | -------------------------------------- |
| Node.js     | 20.9.0+ (LTS); Node 18 unsupported     |
| TypeScript  | 5.1.0+                                 |
| Browsers    | Chrome/Edge/Firefox 111+, Safari 16.4+ |

## The big behavioral inversions (the ones that bite)

1. **Caching is opt-in.** All dynamic code runs at request time by default; `fetch` is not cached. Opt in with
   `"use cache"` (Cache Components). See `caching.md`.
2. **Async request APIs.** `params`, `searchParams`, `cookies()`, `headers()`, `draftMode()` are all async — `await`
   them. Sync access is removed.
3. **`middleware.ts` → `proxy.ts`** (exported `proxy`, Node.js runtime). `middleware.ts` deprecated.
4. **Turbopack is the default bundler** for dev and build. Opt out with `next dev --webpack` / `next build --webpack`.
5. **`next lint` removed.** `next build` no longer lints. Use ESLint (flat config by default now) or Biome directly.
   Codemod: `npx @next/codemod@canary next-lint-to-eslint-cli .`
6. **React Compiler support is stable** (opt-in via `reactCompiler: true`; requires `babel-plugin-react-compiler`; not
   on by default; raises build time since it uses Babel).
7. **React 19.2** features available: View Transitions, `useEffectEvent`, `<Activity>`.

## `next.config.ts` reference (common options)

```ts
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
    cacheComponents: true, // opt into Cache Components / PPR (was experimental.dynamicIO)
    reactCompiler: true, // optional; stable but off by default
    turbopack: {
        /* ... */
    }, // now top-level (moved out of experimental)
    images: {
        remotePatterns: [
            // use this, NOT images.domains (deprecated)
            { protocol: "https", hostname: "cdn.example.com" },
        ],
        // v16 tightened defaults below — override deliberately:
        // qualities default [75]; minimumCacheTTL 14400 (4h); imageSizes dropped 16;
        // maximumRedirects default 3; dangerouslyAllowLocalIP false
        localPatterns: [{ pathname: "/assets/**" }], // needed for local src with query strings
    },
    experimental: {
        turbopackFileSystemCacheForDev: true, // beta: faster restarts on large apps
    },
};
export default nextConfig;
```

## Removed features (with replacements)

| Removed                                                                            | Replacement                                     |
| ---------------------------------------------------------------------------------- | ----------------------------------------------- |
| AMP (`useAmp`, `config = { amp: true }`)                                           | none — removed                                  |
| `next lint`                                                                        | ESLint/Biome directly; codemod available        |
| `devIndicators` options (`appIsrStatus`, `buildActivity`, `buildActivityPosition`) | indicator remains, options gone                 |
| `serverRuntimeConfig`, `publicRuntimeConfig`                                       | env vars (`.env`)                               |
| `experimental.turbopack` location                                                  | top-level `turbopack`                           |
| `experimental.dynamicIO`                                                           | `cacheComponents`                               |
| `experimental.ppr`, `export const experimental_ppr`                                | Cache Components (PPR is default behavior)      |
| automatic `scroll-behavior: smooth`                                                | add `data-scroll-behavior="smooth"` on `<html>` |
| sync `params`/`searchParams`                                                       | `await params` / `await searchParams`           |
| sync `cookies()`/`headers()`/`draftMode()`                                         | async versions                                  |
| `next/image` local src with query strings                                          | now requires `images.localPatterns`             |

## Changed defaults

| Default                          | New behavior                                                              |
| -------------------------------- | ------------------------------------------------------------------------- |
| Bundler                          | Turbopack (opt out: `--webpack`)                                          |
| `images.minimumCacheTTL`         | 60s → 4h (14400s)                                                         |
| `images.imageSizes`              | dropped `16`                                                              |
| `images.qualities`               | `[1..100]` → `[75]`; `quality` prop coerced to nearest allowed            |
| `images.dangerouslyAllowLocalIP` | local IP optimization blocked by default                                  |
| `images.maximumRedirects`        | unlimited → 3                                                             |
| `@next/eslint-plugin-next`       | ESLint flat config by default                                             |
| Prefetch cache                   | rewritten: layout dedup + incremental prefetch                            |
| `revalidateTag()`                | requires `cacheLife` profile as 2nd arg (SWR)                             |
| Parallel route slots             | every slot needs explicit `default.js`/`tsx` or build fails               |
| dev/build output dirs            | separate, enabling concurrent runs; lockfile prevents duplicate instances |
| Babel in Turbopack               | auto-enabled if a babel config is found (no longer a hard error)          |

## Deprecations (still work, will be removed)

- `middleware.ts` filename → rename to `proxy.ts`.
- `next/legacy/image` → `next/image`.
- `images.domains` → `images.remotePatterns`.
- single-arg `revalidateTag(tag)` → `revalidateTag(tag, profile)` or `updateTag(tag)`.

## Codemods & upgrade path

```bash
# Automated upgrade (handles most mechanical changes):
npx @next/codemod@canary upgrade latest

# Or manual:
npm install next@latest react@latest react-dom@latest
```

Recommended sequence after upgrading:

1. Run the codemod; fix what it can't (async params/request APIs especially).
2. Rename `middleware.ts` → `proxy.ts` (+ exported function).
3. Switch `images.domains` → `remotePatterns`; review tightened image defaults.
4. Wire ESLint/Biome since `next build` no longer lints.
5. If adopting Cache Components: enable `cacheComponents`, add `"use cache"` to clearly-static pages first, then
   `cacheLife` profiles, then `cacheTag` + `revalidateTag`/`updateTag` for mutations. Expect previously-static pages to
   render dynamically until cached.
6. Add `default.tsx` to any parallel-route slots.

## 16.1 / 16.2 notable additions

- **16.1**: experimental Turbopack Bundle Analyzer; `next dev --inspect` for the Node debugger; improved
  `serverExternalPackages` for transitive deps.
- **16.2**: AI/agent-focused improvements — agent-ready `create-next-app`, browser log forwarding to the terminal (for
  agent debugging), dev-server lockfile error messages, experimental Agent DevTools; reworked App Router scroll/focus
  management; 200+ Turbopack fixes (Server Fast Refresh, SRI, `postcss.config.ts`, tree-shaking).
- **Next.js DevTools MCP** (since 16): Model Context Protocol integration giving AI agents routing/caching/rendering
  context, unified browser+server logs, automatic error/stack-trace access, and active-route awareness — useful for
  AI-assisted debugging.
