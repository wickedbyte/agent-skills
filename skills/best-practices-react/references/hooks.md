# Hooks

Rules, custom hook design, when not to `useEffect`, and the React 19 hook additions.

## Rules of Hooks (still apply)

1. Only call hooks at the top level of a component or another hook. Not inside loops, conditions, nested functions, or
   after early returns.
2. Only call hooks from React function components or custom hooks. Not from regular functions, not from class methods.

`eslint-plugin-react-hooks` enforces both. The `exhaustive-deps` rule is configured by default for `useEffect`,
`useMemo`, `useCallback`, and `useImperativeHandle`. Leave it on. When the rule asks for a dep you intentionally omit,
the right answer is almost always to restructure (use `useEffectEvent`, lift the value, or use the ref pattern) rather
than to suppress.

## `useState`

```tsx
const [count, setCount] = useState(0); // T inferred
const [user, setUser] = useState<User | null>(null); // explicit when initial is null/undefined

// Lazy initialization — only runs once, on mount
const [tree, setTree] = useState(() => buildExpensiveTree(seed));

// Functional updates when the new state depends on the previous state
setCount((prev) => prev + 1);
```

Anti-patterns:

- `useState<string | undefined>(undefined)` followed by `value!` everywhere. Either give it a real default or model the
  loading/loaded states explicitly.
- Storing derived state. If `fullName = first + " " + last`, compute it during render.
- Storing props in state to "snapshot" them. Use a `key` prop on the component, or just read the prop.

## `useReducer`

Reach for `useReducer` when a state has multiple sub-fields that change together, or when state transitions have
business logic. The reducer pattern composes cleanly with discriminated unions for both state and actions.

```tsx
type State =
    | { status: "idle" }
    | { status: "loading" }
    | { status: "success"; data: Post[] }
    | { status: "error"; error: Error };

type Action =
    | { type: "fetch" }
    | { type: "fetched"; data: Post[] }
    | { type: "failed"; error: Error }
    | { type: "reset" };

function reducer(state: State, action: Action): State {
    switch (action.type) {
        case "fetch":
            return { status: "loading" };
        case "fetched":
            return { status: "success", data: action.data };
        case "failed":
            return { status: "error", error: action.error };
        case "reset":
            return { status: "idle" };
    }
}

const [state, dispatch] = useReducer(reducer, { status: "idle" });
```

For server state, prefer TanStack Query — it gives you `useReducer`-like state shape for free, plus caching and retries.

## `useEffect` — last resort, not first reach

`useEffect` is for synchronizing React with an external system. The cleanest mental model: an effect describes a piece
of _non-React_ state that depends on React state, and the cleanup reverses the synchronization.

Legitimate uses:

```tsx
// ✅ Subscribe to a browser event
useEffect(() => {
    function onResize() {
        setSize({ w: window.innerWidth, h: window.innerHeight });
    }
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
}, []);

// ✅ Imperative integration with a non-React widget
useEffect(() => {
    const map = new MapboxMap({ container: ref.current!, center: [lng, lat] });
    return () => map.remove();
}, [lng, lat]);

// ✅ Set up a subscription to an external store (prefer useSyncExternalStore when available)
useEffect(() => {
    const unsubscribe = store.subscribe((snapshot) => setSnapshot(snapshot));
    return unsubscribe;
}, [store]);

// ✅ Document title or another browser side effect (or use the React 19 Document Metadata APIs instead)
useEffect(() => {
    document.title = `${unread} unread`;
    return () => {
        document.title = "Inbox";
    };
}, [unread]);
```

Illegitimate uses:

| Symptom                                                  | Replace with                                                                         |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Deriving state from props                                | Compute during render                                                                |
| Resetting state when a prop changes                      | `key={prop}` on the component, or a derived state pattern                            |
| Fetching data on mount                                   | Server Component / `use()` / TanStack Query                                          |
| Notifying a parent of a state change                     | Lift state up; call the parent's callback in the same handler that changed the state |
| Listening to your own state change to update other state | Combine both into the same setter, or use `useReducer`                               |
| Initializing state from `localStorage`                   | `useState(() => readFromStorage())` lazy initializer (or `useSyncExternalStore`)     |

The "you might not need an effect" rule: **if the effect runs in response to props or state and then sets more state,
you almost certainly do not need the effect.**

## `useEffectEvent` (React 19.2)

`useEffectEvent` lets you extract non-reactive logic from inside an effect. The returned function reads the _latest_
values of state and props but does not appear in the effect's dep array.

```tsx
import {
    useEffect,
    experimental_useEffectEvent as useEffectEvent,
} from "react";

function ChatRoom({ roomId, theme }: Props) {
    const onConnected = useEffectEvent(() => {
        showNotification(`Connected to ${roomId}`, theme); // reads latest theme without re-running the effect
    });

    useEffect(() => {
        const connection = createConnection(roomId);
        connection.on("connected", () => onConnected());
        connection.connect();
        return () => connection.disconnect();
    }, [roomId]); // theme is intentionally NOT here; the event reads the latest value
}
```

Use `useEffectEvent` when the effect's _setup_ depends on one set of values, but the _event handler inside the setup_
needs to read a different (potentially-changing) set of values. The classic "stale closure" trap is what this hook
solves.

Do not use it as a general escape hatch from `exhaustive-deps`. The rule of thumb: if the function's job is to react to
_changes_ in a value, that value belongs in the dep array. If the function's job is to react to an _event_ and
incidentally read the current value, that value belongs inside `useEffectEvent`.

## `useSyncExternalStore`

When subscribing to an external store (Zustand, Redux without their hooks, a custom event emitter, browser APIs with a
subscription model), `useSyncExternalStore` is the right primitive — it handles concurrent rendering, server rendering,
and tearing correctly:

```tsx
const isOnline = useSyncExternalStore(
    (callback) => {
        window.addEventListener("online", callback);
        window.addEventListener("offline", callback);
        return () => {
            window.removeEventListener("online", callback);
            window.removeEventListener("offline", callback);
        };
    },
    () => navigator.onLine, // client snapshot
    () => true, // server snapshot — assume online during SSR
);
```

Library hooks (Zustand's `useStore`, Redux's `useSelector`) already use this under the hood; you do not need to wire it
manually unless you are implementing a store.

## `useMemo` / `useCallback` in the Compiler era

With the React Compiler enabled, manual memoization is unnecessary and a code smell. The Compiler analyzes the function
and inserts caching where it would matter, _without_ the developer having to think about referential identity.

Three reasons manual memoization still earns its keep:

1. **Stable identity contract** — a value is passed to a library that uses referential identity for cache invalidation (
   older `useEffect` consumers, virtualization libraries, libraries that key off a `Map`). Comment why the memo exists.
2. **The Compiler bailed out** — `eslint-plugin-react-compiler` flags components the Compiler cannot optimize (usually
   because of dynamic property access or other untrackable patterns). For those, manual memoization is a reasonable
   fallback while the bailout reason is fixed.
3. **Measured hot path** — a profile shows the memoization helps. Bench, do not guess.

```tsx
// ✅ Compiler era — let the compiler do its job
function PostList({ posts }: PostListProps) {
    const sorted = posts
        .slice()
        .sort((a, b) => b.publishedAt.localeCompare(a.publishedAt));
    return sorted.map((p) => <PostCard key={p.id} post={p} />);
}

// ✅ Acceptable — manual memoization with a comment explaining why
function PostList({ posts }: PostListProps) {
    // useMemo for stable identity passed to react-virtual's `useVirtualizer`
    const sorted = useMemo(
        () =>
            posts
                .slice()
                .sort((a, b) => b.publishedAt.localeCompare(a.publishedAt)),
        [posts],
    );
    // ...
}
```

For incremental adoption, the `"use memo"` directive opts a single component or hook into Compiler optimization without
enabling it globally:

```tsx
function TodoList({ todos }: TodoListProps) {
    "use memo";
    const sorted = todos.slice().sort((a, b) => a.dueAt.localeCompare(b.dueAt));
    return sorted.map((t) => <TodoItem key={t.id} todo={t} />);
}
```

## Custom hooks

The naming convention is `use<Domain>` or `use<Behavior>`. The hook returns an object (for multiple values) or a tuple (
for `useState`-like positional pairs).

```tsx
// ✅ Domain-named, object return — typical
interface UseUserResult {
    readonly user: User | null;
    readonly isLoading: boolean;
    readonly error: Error | null;
    readonly refetch: () => void;
}

export function useUser(id: string): UseUserResult {
    const query = useQuery({
        queryKey: ["user", id],
        queryFn: () => fetchUser(id),
    });
    return {
        user: query.data ?? null,
        isLoading: query.isPending,
        error: query.error,
        refetch: () => query.refetch(),
    };
}

// ✅ useState-shaped tuple — when callers will use positional destructuring
export function useToggle(initial = false): readonly [boolean, () => void] {
    const [value, setValue] = useState(initial);
    return [value, () => setValue((v) => !v)];
}
```

Avoid:

- `useState2`, `useHelper`, `useThing` — vague.
- `getUser`, `fetchUser` (no `use` prefix on a hook).
- A hook that returns more than one tuple position with mixed semantics (`[user, login, logout, isLoading]`) — switch to
  an object.

## Custom hooks worth writing

```tsx
// useDebouncedValue
export function useDebouncedValue<T>(value: T, delayMs: number): T {
    const [debounced, setDebounced] = useState(value);
    useEffect(() => {
        const id = setTimeout(() => setDebounced(value), delayMs);
        return () => clearTimeout(id);
    }, [value, delayMs]);
    return debounced;
}

// useLocalStorage — server-safe with useSyncExternalStore
export function useLocalStorage(
    key: string,
): readonly [string | null, (next: string | null) => void] {
    const value = useSyncExternalStore(
        (callback) => {
            window.addEventListener("storage", callback);
            return () => window.removeEventListener("storage", callback);
        },
        () => window.localStorage.getItem(key),
        () => null,
    );
    const setValue = useCallback(
        (next: string | null) => {
            if (next === null) window.localStorage.removeItem(key);
            else window.localStorage.setItem(key, next);
            window.dispatchEvent(new StorageEvent("storage", { key }));
        },
        [key],
    );
    return [value, setValue];
}

// useIsomorphicLayoutEffect — silence SSR warnings
export const useIsomorphicLayoutEffect =
    typeof window !== "undefined" ? useLayoutEffect : useEffect;
```

These compose with Server Components correctly because they are explicitly client-only — they live in a `"use client"`
module.

## Hook composition

Compose hooks by calling them from other hooks. The compiler enforces the rules of hooks across the composition
automatically.

```tsx
export function useDebouncedSearchResults(query: string, delayMs = 300) {
    const debounced = useDebouncedValue(query, delayMs);
    const result = useQuery({
        queryKey: ["search", debounced],
        queryFn: () => fetchSearchResults(debounced),
        enabled: debounced.length > 0,
    });
    return { results: result.data ?? [], isLoading: result.isPending };
}
```

## When to extract a custom hook

Extract when:

- The same hook sequence appears in more than one component.
- The logic is testable on its own (a `useDebouncedValue` test is much simpler than a "test that the search box
  debounces" test).
- The component is doing too much — a focused hook moves the _what_ into the hook and leaves the _render_ in the
  component.

Do not extract when:

- The hook is used in exactly one place and adds no meaningful name.
- The "hook" wraps a single `useState` with no additional behavior.

The rule of thumb: a custom hook is a _named piece of stateful logic_. If you cannot name it for the domain, it does not
deserve to be a hook yet.
