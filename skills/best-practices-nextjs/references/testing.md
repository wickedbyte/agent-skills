# Testing Next.js 16

The current (2026) testing stack and how to apply it to App Router code. The stack is forced partly by tooling: **async
Server Components cannot be rendered in jsdom yet**, so the layer split below is not optional.

## Contents

- The stack and the layer split
- Setup: Vitest + RTL
- Setup: Playwright
- MSW for network mocking
- Testing synchronous Server & Client Components
- Testing async Server Components (E2E)
- Testing Server Actions
- Testing Route Handlers
- Testing forms (`useActionState`)
- What to test and what to skip
- CI gating

## The stack and the layer split

- **Vitest + React Testing Library (RTL)** — unit/component tests for: synchronous Server Components, Client Components,
  Server Actions (as plain functions), Zod schemas, and utilities. Vitest replaced Jest as the default for new
  projects (Vite-native, faster, near-identical API).
- **Playwright** — end-to-end tests for: async Server Components, auth flows, multi-step journeys, anything needing a
  real browser (SSR + hydration + navigation).
- **MSW (Mock Service Worker)** — realistic network mocking shared across unit and E2E.

**The hard rule:** Vitest/jsdom cannot render `async` Server Components (React's async component support isn't stable in
the test runner). Unit-test the synchronous parts; cover async Server Components with Playwright. A common, pragmatic
refactor: pull the async data fetch into a plain async function, unit-test _that function_ with Vitest, and let the
component become a thin wrapper covered by E2E.

## Setup: Vitest + RTL

```bash
pnpm add -D vitest @vitejs/plugin-react jsdom \
  @testing-library/react @testing-library/dom @testing-library/jest-dom \
  @testing-library/user-event vite-tsconfig-paths
```

```ts
// vitest.config.ts
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
    plugins: [tsconfigPaths(), react()],
    test: {
        environment: "jsdom",
        globals: true,
        setupFiles: ["./vitest.setup.ts"],
    },
});
```

```ts
// vitest.setup.ts
import "@testing-library/jest-dom/vitest";
```

You can also scaffold via `pnpm create next-app --example with-vitest`.

## Setup: Playwright

```bash
pnpm add -D @playwright/test && pnpm exec playwright install
```

```ts
// playwright.config.ts
import { defineConfig } from "@playwright/test";
export default defineConfig({
    testDir: "./e2e",
    use: { baseURL: "http://localhost:3000" },
    webServer: {
        command: "pnpm build && pnpm start", // test the production build
        url: "http://localhost:3000",
        reuseExistingServer: !process.env.CI,
    },
});
```

Test against `next build && next start` (production behavior), not `next dev`.

## MSW for network mocking

Define request handlers once and reuse them in Vitest (node) and Playwright. Mock third-party/external HTTP so tests are
deterministic; prefer hitting your own real DB/test-DB for integration-level confidence where feasible.

## Testing synchronous Server & Client Components

```tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Counter } from "./counter";

test("increments on click", async () => {
    render(<Counter />);
    await userEvent.click(screen.getByRole("button", { name: /increment/i }));
    expect(screen.getByText("1")).toBeInTheDocument();
});
```

Query by role/label/text (user-facing), not by test IDs or implementation details. Use `userEvent` over `fireEvent`.

## Testing async Server Components (E2E)

```ts
// e2e/products.spec.ts
import { test, expect } from "@playwright/test";

test("product page shows details", async ({ page }) => {
    await page.goto("/products/123");
    await expect(page.getByRole("heading", { name: /widget/i })).toBeVisible();
    await page.getByRole("button", { name: /add to cart/i }).click();
    await expect(page.getByText(/added/i)).toBeVisible();
});
```

## Testing Server Actions

Server Actions are plain async functions — import and call them directly in Vitest, mocking the DB/auth layer:

```ts
import { describe, it, expect, vi } from "vitest";
import { createPost } from "./actions";

vi.mock("@/lib/auth", () => ({ auth: vi.fn(async () => ({ userId: "u1" })) }));
vi.mock("@/lib/db", () => ({ db: { posts: { create: vi.fn() } } }));

it("rejects empty title", async () => {
    const fd = new FormData();
    fd.set("title", "");
    fd.set("body", "hi");
    const res = await createPost({ ok: false }, fd);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.fieldErrors?.title).toBeDefined();
});
```

Test the security/validation branches explicitly: unauthenticated, invalid input, unauthorized, happy path.

## Testing Route Handlers

Import the exported method and pass a `Request`/`NextRequest`:

```ts
import { POST } from "./route";

it("returns 400 on invalid body", async () => {
    const req = new Request("http://test/api/posts", {
        method: "POST",
        body: JSON.stringify({}),
    });
    const res = await POST(req as any);
    expect(res.status).toBe(400);
});
```

## Testing forms (`useActionState`)

For the client form component, render it in RTL with the action mocked, and assert that error/pending UI renders for
each state. For the full submit→server→revalidate journey, use Playwright.

## What to test and what to skip

**Test:** user-facing behavior, Server Action validation/auth/authorization branches, schema edge cases, route handler
status codes, critical journeys (signup, checkout, auth) in E2E, accessibility roles.

**Skip:** that a library primitive (e.g. a shadcn `<Button>`) renders a `<button>` — it's tested upstream; snapshot
tests that serialize hundreds of lines of HTML and break on any style change; tests asserting TypeScript prop types (the
compiler covers that); internal state variables. Aim for fewer, behavior-focused tests over many brittle implementation
tests.

## CI gating

Run tiers sequentially, fastest first, parallel within a tier:

1. `tsc --noEmit` (typecheck) + ESLint (recall `next build` no longer lints).
2. Vitest unit/component (`--reporter=github` for inline PR annotations).
3. `next build`.
4. Playwright E2E against the built app.

Fail fast: if a cheaper tier fails, don't run the expensive ones.
