# Testing

Vitest + React Testing Library + MSW for component and integration tests. Playwright for end-to-end and high-fidelity
component tests. Type-level tests for component APIs.

## The stack

| Concern                               | Tool                                                           |
| ------------------------------------- | -------------------------------------------------------------- |
| Test runner                           | **Vitest** (or Node's built-in test runner for non-React libs) |
| Render + DOM queries                  | **@testing-library/react**                                     |
| User interaction                      | **@testing-library/user-event**                                |
| API mocking                           | **MSW (Mock Service Worker)**                                  |
| Type-level tests for component APIs   | **`expectTypeOf` (Vitest typecheck mode)** or **`tsd`**        |
| Browser-fidelity E2E and visual tests | **Playwright**                                                 |
| Visual regression                     | **Playwright** or **Chromatic**                                |

Avoid Jest + ts-jest + a separate transpiler in new projects — the modern stack is faster and less ceremonial.

## Vitest setup

```ts
// vitest.config.ts
import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
    plugins: [react(), tsconfigPaths()],
    test: {
        environment: "jsdom",
        setupFiles: ["./test/setup.ts"],
        globals: false, // prefer explicit imports
        css: true, // process CSS imports for tests that depend on styles
    },
});
```

```ts
// test/setup.ts
import "@testing-library/jest-dom/vitest";
import { afterEach } from "vitest";
import { cleanup } from "@testing-library/react";

afterEach(() => cleanup());
```

`@testing-library/jest-dom/vitest` extends Vitest's `expect` with `toBeInTheDocument`, `toHaveTextContent`,
`toBeDisabled`, etc.

## Anatomy of a component test

```tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { expect, test, vi } from "vitest";
import { PostCard } from "./post-card.js";

const samplePost: Post = {
    id: "p1",
    title: "Hello, world",
    excerpt: "First post",
    publishedAt: "2026-06-01T00:00:00Z",
    readingTime: 3,
};

test("renders title and excerpt", () => {
    render(<PostCard post={samplePost} />);
    expect(
        screen.getByRole("heading", { name: "Hello, world" }),
    ).toBeInTheDocument();
    expect(screen.getByText("First post")).toBeInTheDocument();
});

test("invokes onSelect when clicked", async () => {
    const user = userEvent.setup();
    const onSelect = vi.fn();
    render(<PostCard post={samplePost} onSelect={onSelect} />);
    await user.click(screen.getByRole("article"));
    expect(onSelect).toHaveBeenCalledWith(samplePost);
});
```

## Query priority

```
getByRole > getByLabelText > getByPlaceholderText > getByText > getByDisplayValue > getByAltText > getByTitle > getByTestId
```

Use the highest item that uniquely identifies the element.

```tsx
// ✅
screen.getByRole("button", { name: "Save" });
screen.getByRole("textbox", { name: "Title" });
screen.getByRole("heading", { name: "Posts", level: 1 });

// ⚠️ Acceptable but less robust
screen.getByText("Save");

// ❌ Last resort — implies missing accessibility metadata
screen.getByTestId("save-button");
```

If a test wants to use `getByTestId`, that is usually a hint to fix the component's accessibility instead.

### `find` vs. `get` vs. `query`

| Prefix     | Async? | Returns                                        | When                                    |
| ---------- | ------ | ---------------------------------------------- | --------------------------------------- |
| `getBy*`   | No     | Element (throws if not found)                  | The element is in the DOM synchronously |
| `findBy*`  | Yes    | Promise<Element> (waits, throws after timeout) | The element appears async               |
| `queryBy*` | No     | Element \| null                                | Asserting absence                       |

```tsx
// ✅ Wait for async appearance
expect(await screen.findByRole("alert")).toHaveTextContent("Saved");

// ✅ Assert absence
expect(screen.queryByRole("alert")).not.toBeInTheDocument();

// ❌ Race
expect(screen.getByRole("alert")).toBeInTheDocument(); // throws immediately if not yet rendered
```

## `userEvent`, not `fireEvent`

`userEvent` simulates real user interactions (focus, keypress sequence, modifier keys, scrolling) and is the default.
`fireEvent` is the raw DOM event helper and is rarely the right choice.

```tsx
const user = userEvent.setup();
await user.type(screen.getByRole("textbox", { name: "Title" }), "Hello");
await user.click(screen.getByRole("button", { name: "Save" }));
await user.keyboard("{Escape}");
await user.tab();
```

`userEvent.setup()` returns a session-scoped object — call it once per test. `user.type` correctly fires
keydown/keypress/input/keyup events, respects focus, and handles modifier keys.

## Mocking the network with MSW

MSW intercepts network requests at the service-worker / Node-fetch layer. The test exercises your real data layer (
fetch / Axios / TanStack Query / SDK calls), and MSW returns whatever the test wants.

```ts
// test/mocks/handlers.ts
import { http, HttpResponse } from "msw";

export const handlers = [
    http.get("/api/posts", () =>
        HttpResponse.json([{ id: "p1", title: "Mocked" }]),
    ),
    http.get("/api/posts/:id", ({ params }) =>
        HttpResponse.json({ id: params.id, title: `Mocked ${params.id}` }),
    ),
    http.post("/api/posts", async ({ request }) => {
        const body = await request.json();
        return HttpResponse.json({ id: "new", ...body }, { status: 201 });
    }),
];

// test/mocks/server.ts (Node — for Vitest)
import { setupServer } from "msw/node";
import { handlers } from "./handlers.js";
export const server = setupServer(...handlers);
```

```ts
// test/setup.ts
import { afterAll, afterEach, beforeAll } from "vitest";
import { server } from "./mocks/server.js";

beforeAll(() => server.listen({ onUnhandledRequest: "error" }));
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
```

In individual tests, override handlers per test:

```ts
test("shows error on 500", async () => {
  server.use(http.get("/api/posts", () => new HttpResponse(null, { status: 500 })));
  render(<PostsPage />);
  expect(await screen.findByRole("alert")).toHaveTextContent(/failed/i);
});
```

This pattern tests _what the user sees_, not _which function was called_. That is more durable when refactoring.

## Testing components that use TanStack Query

Wrap the render in a fresh `QueryClient` per test to avoid cross-test cache leaks:

```tsx
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

function renderWithQuery(ui: React.ReactNode) {
    const queryClient = new QueryClient({
        defaultOptions: { queries: { retry: false } },
    });
    return render(
        <QueryClientProvider client={queryClient}>{ui}</QueryClientProvider>,
    );
}

test("renders posts", async () => {
    renderWithQuery(<PostsList />);
    expect(await screen.findByText("Mocked")).toBeInTheDocument();
});
```

`retry: false` is important — default retries make assertion timing unpredictable in tests.

## Testing components that use a router

Each router provides a test helper:

- **React Router**: `createMemoryRouter` and `<RouterProvider router={memoryRouter}>`.
- **TanStack Router**: `createMemoryHistory` + `createRouter` with the routes you care about.
- **Next.js App Router**: more involved; the official guidance is to use Playwright for routes that depend on
  server-side execution, and unit-test client components in isolation by avoiding `useRouter`/`useSearchParams` in pure
  UI logic.

```tsx
import { MemoryRouter, Routes, Route } from "react-router";

render(
    <MemoryRouter initialEntries={["/posts/p1"]}>
        <Routes>
            <Route path="/posts/:id" element={<Post />} />
        </Routes>
    </MemoryRouter>,
);
```

## Testing forms

```tsx
test("submits valid post", async () => {
    const user = userEvent.setup();
    render(<CreatePostForm />);
    await user.type(screen.getByRole("textbox", { name: "Title" }), "Hello");
    await user.type(screen.getByRole("textbox", { name: "Body" }), "World");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(await screen.findByText("Saved")).toBeInTheDocument();
});

test("shows validation error", async () => {
    const user = userEvent.setup();
    render(<CreatePostForm />);
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(/required/i);
});
```

For react-hook-form, the form validates on submit by default. Trigger submit and assert on the error alerts.

For React 19 Actions, the Action itself is invoked — either mock the Action (
`vi.mock("./actions.js", () => ({ createPost: vi.fn().mockResolvedValue({ error: null }) }))`) or let MSW intercept the
underlying request the Action makes.

## Type-level tests

Component APIs benefit from type tests, especially for libraries and shared components:

```ts
// button.test-d.ts
import { expectTypeOf, test } from "vitest";
import { Button } from "./button.js";

test("variant prop is constrained", () => {
  expectTypeOf<React.ComponentProps<typeof Button>>().toHaveProperty("variant").toEqualTypeOf<"primary" | "secondary" | "ghost" | undefined>();
});

test("polymorphic select preserves T", () => {
  const value: { id: number; label: string } = { id: 1, label: "One" };
  expectTypeOf(<Select options={[value]} value={value} onChange={(v) => v.id} getLabel={(v) => v.label} getKey={(v) => v.id} />).not.toBeAny();
});
```

Run via `vitest --typecheck` or with `tsd` for stricter assertions.

## Testing Server Components

Server Components are functions that return JSX (or `Promise<JSX>`). They are testable as regular async functions:

```tsx
import { test, expect } from "vitest";
import { renderToString } from "react-dom/server";
import PostsPage from "@/app/posts/page";

test("renders posts page", async () => {
    // Server components can be awaited and rendered to string
    const ui = await PostsPage({
        params: Promise.resolve({}),
        searchParams: Promise.resolve({}),
    });
    const html = renderToString(ui as React.ReactElement);
    expect(html).toContain("Posts");
});
```

For richer Server Component tests (with full RSC payload streaming), Next.js's built-in `next test` integration (Next
16+) or Playwright against a dev server is more representative.

## Playwright for end-to-end

```ts
// e2e/posts.spec.ts
import { test, expect } from "@playwright/test";

test("can create a post", async ({ page }) => {
    await page.goto("/posts/new");
    await page.getByRole("textbox", { name: "Title" }).fill("E2E post");
    await page.getByRole("textbox", { name: "Body" }).fill("From Playwright");
    await page.getByRole("button", { name: "Save" }).click();
    await expect(page).toHaveURL(/\/posts\/[a-z0-9-]+$/);
    await expect(page.getByRole("heading", { name: "E2E post" })).toBeVisible();
});
```

Playwright also supports component testing in real browsers — useful when JSDOM lacks fidelity (CSS layout queries,
complex pointer events, real focus traps).

## Test what the user sees, not what the code does

The single most durable heuristic:

- ✅ "After the user fills the form and clicks Save, an alert with text 'Saved' appears."
- ❌ "After the user clicks Save, `createPostMutation.mutate` is called with `{ title, body }`."

The first test survives refactors of the data layer. The second breaks every time you rename a function. Asserting on
user-visible behavior gives you change-tolerant tests.

Exceptions: test the data layer separately (unit tests for query hooks, type tests for component APIs, contract tests
against the backend with MSW recordings). Those tests pin specific function behavior; the integration tests above pin
observable behavior.

## Common mistakes

| Mistake                                 | Fix                                                                             |
| --------------------------------------- | ------------------------------------------------------------------------------- |
| `getByTestId` everywhere                | `getByRole` with accessible name                                                |
| `fireEvent.click(...)`                  | `userEvent.click(...)`                                                          |
| `setTimeout` inside a test              | `await findBy*` or `waitFor`                                                    |
| Shared `QueryClient` across tests       | Fresh `QueryClient` per test                                                    |
| Mocking `fetch` directly                | MSW                                                                             |
| Asserting on internal function calls    | Assert on what the user sees                                                    |
| `act()` warnings ignored                | Wrap state updates that trigger renders, or use `await` on `findBy*` / `user.*` |
| Tests that depend on snapshot output    | Snapshot tests rot fast; prefer behavioral assertions                           |
| Testing component types only at runtime | Pair with `expectTypeOf` / `tsd`                                                |
| Forgetting `cleanup()` between tests    | The setup file should call it automatically                                     |
