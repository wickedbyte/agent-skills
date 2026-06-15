# State Management

Pick the right tool for the _kind_ of state. Most React state problems are actually identification problems — once you
know which category the state belongs to, the tool is obvious.

## The four kinds of state

| Kind                      | What it is                                                          | Right tool                              |
| ------------------------- | ------------------------------------------------------------------- | --------------------------------------- |
| **Server state**          | Data owned by a server, cached on the client, possibly stale        | TanStack Query, or RSC + Server Actions |
| **URL state**             | Filters, pagination, sort, modal-is-open, current tab               | Router's typed search params API        |
| **Local component state** | UI toggles, form inputs, ephemeral interactions                     | `useState` / `useReducer`               |
| **Global client state**   | Theme, auth user, settings, shared client-only state across screens | Zustand / Jotai / React Context         |

Most beginner mistakes come from putting state in the wrong category:

- Putting server data in Redux / Zustand → stale data, complicated invalidation.
- Putting filter state in `useState` → broken back button, no sharing via URL.
- Putting form state in global state → reactivity storms, hard to test.

## Server state — TanStack Query

TanStack Query (`@tanstack/react-query`, v5) is the default for any server data on the client. It handles caching,
deduplication, retries, staleness, refetch on focus/reconnect, mutations with optimistic updates, infinite scroll,
pagination, and prefetching.

```tsx
import { useQuery } from "@tanstack/react-query";

function PostsList() {
    const query = useQuery({
        queryKey: ["posts"],
        queryFn: async () => {
            const response = await fetch("/api/posts");
            if (!response.ok) throw new Error("Failed to load posts");
            return Posts.parse(await response.json());
        },
        staleTime: 60_000, // 1 minute fresh; tune per query
    });

    if (query.isPending) return <Spinner />;
    if (query.isError) return <Error error={query.error} />;
    return (
        <ul>
            {query.data.map((p) => (
                <li key={p.id}>{p.title}</li>
            ))}
        </ul>
    );
}
```

### Query keys

Keys are arrays. Identify the resource and any parameters that affect the result:

```ts
["posts"][("posts", { tag })][("posts", id)][("posts", id, "comments")]; // all posts // posts filtered by tag // a single post // comments of a single post
```

Define key factories so they stay consistent:

```ts
// data/post-keys.ts
export const postKeys = {
    all: ["posts"] as const,
    lists: () => [...postKeys.all, "list"] as const,
    list: (filters: PostFilters) => [...postKeys.lists(), filters] as const,
    details: () => [...postKeys.all, "detail"] as const,
    detail: (id: string) => [...postKeys.details(), id] as const,
};
```

Then invalidation can be coarse or precise:

```ts
queryClient.invalidateQueries({ queryKey: postKeys.all }); // all posts
queryClient.invalidateQueries({ queryKey: postKeys.detail(id) }); // one post
```

### Mutations

```tsx
const updatePost = useMutation({
    mutationFn: (input: UpdatePostInput) =>
        fetch(`/api/posts/${input.id}`, {
            method: "PATCH",
            body: JSON.stringify(input),
            headers: { "content-type": "application/json" },
        }).then((r) => {
            if (!r.ok) throw new Error("Failed");
            return r.json();
        }),
    onSuccess: (_, variables) => {
        queryClient.invalidateQueries({
            queryKey: postKeys.detail(variables.id),
        });
        queryClient.invalidateQueries({ queryKey: postKeys.lists() });
    },
});

// usage
<button
    onClick={() => updatePost.mutate({ id, title: "New title" })}
    disabled={updatePost.isPending}
>
    {updatePost.isPending ? "Saving…" : "Save"}
</button>;
```

### Suspense mode

TanStack Query supports React Suspense via `useSuspenseQuery`. The component suspends until the data is ready, the error
boundary catches errors, and `query.data` is always defined inside the component body.

```tsx
function Post({ id }: { readonly id: string }) {
    const { data: post } = useSuspenseQuery({
        queryKey: postKeys.detail(id),
        queryFn: () => fetchPost(id),
    });
    return <article>{post.title}</article>;
}
```

This pairs naturally with `<Suspense fallback={...}>` and an `<ErrorBoundary>`.

### Server-side rendering / hydration

In an SSR app (Next.js, TanStack Start), prefetch on the server and dehydrate to the client:

```tsx
// server
import {
    dehydrate,
    HydrationBoundary,
    QueryClient,
} from "@tanstack/react-query";

async function PostsPage() {
    const queryClient = new QueryClient();
    await queryClient.prefetchQuery({
        queryKey: postKeys.all,
        queryFn: getPosts,
    });
    return (
        <HydrationBoundary state={dehydrate(queryClient)}>
            <PostsList />
        </HydrationBoundary>
    );
}
```

## URL state — the router's typed search params

Filters, pagination, current tab, "modal is open" — these belong in the URL. The user can share, bookmark, and use the
back button.

In TanStack Router, search params are first-class and typed via Zod or Valibot:

```ts
import { z } from "zod";

const searchSchema = z.object({
  q: z.string().optional(),
  page: z.number().int().nonnegative().default(0),
  sort: z.enum(["recent", "popular"]).default("recent"),
});

export const Route = createFileRoute("/posts")({
  validateSearch: searchSchema,
  component: PostsPage,
});

function PostsPage() {
  const { q, page, sort } = Route.useSearch();
  const navigate = Route.useNavigate();
  return (
    <>
      <input value={q ?? ""} onChange={e => navigate({ search: prev => ({ ...prev, q: e.target.value, page: 0 }) })} />
      ...
    </>
  );
}
```

In React Router 7 and Next.js, use `useSearchParams` and validate with a schema:

```tsx
"use client";
import { useSearchParams, useRouter, usePathname } from "next/navigation";
import { z } from "zod";

const params = z.object({
    q: z.string().optional(),
    page: z.coerce.number().int().nonnegative().default(0),
});

function PostsPage() {
    const sp = useSearchParams();
    const router = useRouter();
    const pathname = usePathname();
    const { q, page } = params.parse(Object.fromEntries(sp));

    function update(next: Partial<{ q: string; page: number }>) {
        const merged = { q, page, ...next };
        const newSp = new URLSearchParams();
        if (merged.q !== undefined) newSp.set("q", merged.q);
        if (merged.page !== 0) newSp.set("page", String(merged.page));
        router.replace(`${pathname}?${newSp.toString()}`);
    }
    // ...
}
```

A custom `useSearchParamsState<T>(schema)` hook is worth writing once per project.

## Local component state — `useState` / `useReducer`

For state that exists only within one component (or its children):

- **`useState`** for simple values: a toggle, an input, a counter.
- **`useReducer`** when multiple sub-fields change together, when transitions have logic, or when the state is a
  discriminated union of phases (`idle | loading | success | error`).
- **Lift state up** when two sibling components need the same state. Add the state to the closest common parent; pass
  down as props; pass a setter up as a callback.

If a component has more than four or five `useState`s, ask whether they should be one `useReducer` or whether some of
them are actually URL state, server state, or derived values.

## Global client state — Zustand or Jotai

When state genuinely needs to be shared across many components without prop drilling and is not server data, use a small
state library:

### Zustand — store-based, dead simple

```ts
import { create } from "zustand";

interface UIStore {
    readonly theme: "light" | "dark";
    readonly sidebarOpen: boolean;
    readonly setTheme: (theme: "light" | "dark") => void;
    readonly toggleSidebar: () => void;
}

export const useUIStore = create<UIStore>((set) => ({
    theme: "light",
    sidebarOpen: false,
    setTheme: (theme) => set({ theme }),
    toggleSidebar: () => set((state) => ({ sidebarOpen: !state.sidebarOpen })),
}));

// usage
const theme = useUIStore((state) => state.theme);
const toggle = useUIStore((state) => state.toggleSidebar);
```

Best for: a small number of focused stores, app-wide settings, persisted UI preferences. Persistence is one line via the
`persist` middleware.

### Jotai — atomic, fine-grained

```ts
import { atom, useAtom, useAtomValue } from "jotai";

export const themeAtom = atom<"light" | "dark">("light");
export const sidebarOpenAtom = atom(false);

// derived atom
export const isDarkAtom = atom((get) => get(themeAtom) === "dark");

// usage
const [theme, setTheme] = useAtom(themeAtom);
const isDark = useAtomValue(isDarkAtom);
```

Best for: many independent atoms that combine and derive freely, fine-grained subscriptions, when the "store" mental
model feels heavy.

### Redux / Redux Toolkit

Still valid in existing codebases. For greenfield 2026 React, the default is no longer Redux — server state goes to
TanStack Query, client state to Zustand or Jotai, URL state to the router. Redux still earns its keep in apps with deep
undo/redo needs, dev-tools-driven debugging requirements, or large teams already invested in it.

## React Context

Context is for **passing data through the tree without prop drilling**. It is not a state manager — combining Context
with `useState`/`useReducer` _is_ the pattern.

```tsx
interface AuthContextValue {
    readonly user: User | null;
    readonly logout: () => Promise<void>;
}
const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({
    children,
}: {
    readonly children: React.ReactNode;
}) {
    const [user, setUser] = useState<User | null>(null);
    const logout = useCallback(async () => {
        await api.logout();
        setUser(null);
    }, []);
    return <AuthContext value={{ user, logout }}>{children}</AuthContext>;
}

export function useAuth(): AuthContextValue {
    const ctx = use(AuthContext);
    if (ctx === null)
        throw new Error("useAuth must be used inside <AuthProvider>");
    return ctx;
}
```

Notes:

- React 19's `use(Context)` is the modern read API (replaces `useContext`).
- Throw inside the custom hook if the context is unavailable. Callers should not have to handle the null case at each
  call site.
- React 19 lets you write `<AuthContext value={...}>` instead of `<AuthContext.Provider value={...}>`.
- Context re-renders all consumers when the value's reference changes. For frequently-updating values (mouse position,
  current time), split into multiple contexts or use a state library — the re-render cost is real.

## When state is actually derived

The single biggest beginner mistake is storing values that are derived from other values:

```tsx
// ❌
const [posts, setPosts] = useState<Post[]>([]);
const [filter, setFilter] = useState("");
const [filtered, setFiltered] = useState<Post[]>([]);
useEffect(() => {
    setFiltered(posts.filter((p) => p.title.includes(filter)));
}, [posts, filter]);

// ✅
const [posts, setPosts] = useState<Post[]>([]);
const [filter, setFilter] = useState("");
const filtered = posts.filter((p) => p.title.includes(filter));
```

The `filtered` value is fully determined by `posts` and `filter`. Storing it in state means you can be wrong (state out
of sync with inputs). Computing it during render means you cannot be wrong.

With the React Compiler, even expensive derivations are memoized for you. Compute during render unless profiling proves
otherwise.

## Form state

See `references/forms.md`. The short version:

- React 19 Actions + `useActionState` is the default for forms with simple state.
- react-hook-form + a Zod resolver for forms with complex validation, dynamic fields, multi-step flows, or fine-grained
  dirty tracking.
- Do not put form state in Zustand / Redux. Forms are local component state.

## Anti-patterns

| Pattern                                                                | Why it is wrong                                                                      |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Fetching data into a Zustand store                                     | Zustand does not understand staleness, refetch, retries, dedupe — use TanStack Query |
| Storing URL data only in component state                               | Back button broken; not shareable                                                    |
| Many `useState`s where one `useReducer` would be clearer               | Transitions become implicit and hard to follow                                       |
| Storing derived state                                                  | State can fall out of sync with its inputs                                           |
| Putting form state in global state                                     | Reactivity storms; hard to test                                                      |
| A "useStore" hook that wraps `useContext` and forgets the null check   | Every call site has to handle `null`                                                 |
| Using Redux/Zustand for "the user"                                     | Fine if it really is global; usually Context + `useState` is enough                  |
| Refetching server data in a `useEffect` instead of `invalidateQueries` | Bypasses TanStack Query's cache                                                      |
