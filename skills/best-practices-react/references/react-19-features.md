# React 19 Features

The APIs that changed React idioms in 2024-2025 and that are now the default expectation. Baseline: React 19.2.

## `use()` — read promises and Context in render

The `use()` hook reads a promise or a Context. Unlike other hooks, `use()` can be called conditionally and inside
loops — it follows the rendering rules of Suspense, not the Rules of Hooks.

```tsx
import { use, Suspense } from "react";

interface PostProps {
    readonly postPromise: Promise<Post>;
}

function Post({ postPromise }: PostProps): React.ReactNode {
    const post = use(postPromise); // suspends until the promise resolves
    return <article>{post.title}</article>;
}

// usage
export default function PostPage({ id }: { id: string }) {
    const postPromise = getPost(id); // returns a promise — kept stable across renders
    return (
        <Suspense fallback={<Spinner />}>
            <Post postPromise={postPromise} />
        </Suspense>
    );
}
```

Two subtleties:

- The promise passed into `use()` must be **stable across renders** (or come from a Server Component, which cache
  automatically). Creating `fetch(...)` directly in render and passing it to `use()` would re-fetch every render. Cache
  it with `React.cache()`, with TanStack Query's `prefetchQuery + getQueryData`, or by lifting it to a Server Component.
- `use(Context)` replaces `useContext` and is allowed inside conditions. It is the modern preferred form.

## Actions and `useActionState`

Actions are async functions that React invokes for form submissions (and other UI actions). React tracks pending state,
errors, and result state for you.

```tsx
"use client";

import { useActionState } from "react";
import { createPost } from "./actions.js";

interface FormState {
    readonly error: string | null;
    readonly id?: string;
}

const initialState: FormState = { error: null };

export function CreatePostForm() {
    const [state, formAction, isPending] = useActionState<FormState, FormData>(
        createPost,
        initialState,
    );

    return (
        <form action={formAction}>
            <label>
                Title <input name="title" required />
            </label>
            <label>
                Body <textarea name="body" required />
            </label>

            {state.error !== null && <p role="alert">{state.error}</p>}

            <button type="submit" disabled={isPending}>
                {isPending ? "Saving…" : "Save"}
            </button>
        </form>
    );
}
```

The action signature:

```ts
// actions.ts — Server Action (Next.js / RSC frameworks) or just an async function
"use server";

import { redirect } from "next/navigation";

export async function createPost(
    prev: FormState,
    formData: FormData,
): Promise<FormState> {
    const title = formData.get("title");
    const body = formData.get("body");
    if (typeof title !== "string" || typeof body !== "string") {
        return { error: "Invalid input" };
    }
    try {
        const post = await db.posts.insert({ title, body });
        redirect(`/posts/${post.id}`);
    } catch (err) {
        return { error: err instanceof Error ? err.message : "Unknown error" };
    }
}
```

Why this matters:

- Form submission works without JS — progressive enhancement.
- The action runs on the server (when used with Server Actions) and the client receives only the resulting state. No "
  fetch from a `useEffect`" needed.
- `isPending` and `state` are managed for you. No manual `isLoading` / `error` state.
- Combines with `useFormStatus` and `useOptimistic` for richer UX.

## `useFormStatus` — read the parent form's submission state

```tsx
"use client";
import { useFormStatus } from "react-dom";

export function SubmitButton({
    children,
}: {
    readonly children: React.ReactNode;
}) {
    const { pending } = useFormStatus();
    return (
        <button type="submit" disabled={pending}>
            {pending ? "Saving…" : children}
        </button>
    );
}

// usage — the button discovers the parent form's status automatically
<form action={formAction}>
    ...
    <SubmitButton>Save post</SubmitButton>
</form>;
```

`useFormStatus` is read from inside a child of the `<form>`. It is the right tool for "show a spinner on the submit
button while the parent form is submitting" without having to thread `isPending` through the tree.

## `useOptimistic` — optimistic UI on top of an Action

```tsx
"use client";

import { useOptimistic } from "react";
import { sendMessage } from "./actions.js";

interface Message {
    readonly id: string;
    readonly body: string;
    readonly sending?: boolean;
}

export function ChatBox({
    messages,
}: {
    readonly messages: readonly Message[];
}) {
    const [optimisticMessages, addOptimistic] = useOptimistic(
        messages,
        (state, newMessage: Message) => [
            ...state,
            { ...newMessage, sending: true },
        ],
    );

    async function send(formData: FormData): Promise<void> {
        const body = formData.get("body");
        if (typeof body !== "string") return;
        addOptimistic({ id: crypto.randomUUID(), body });
        await sendMessage(body);
    }

    return (
        <>
            <ul>
                {optimisticMessages.map((m) => (
                    <li
                        key={m.id}
                        style={{ opacity: m.sending === true ? 0.5 : 1 }}
                    >
                        {m.body}
                    </li>
                ))}
            </ul>
            <form action={send}>
                <input name="body" required />
                <button type="submit">Send</button>
            </form>
        </>
    );
}
```

The optimistic state is rolled back automatically if the underlying state (`messages`) does not reflect the optimistic
update after the action resolves. The pending-state tracking is automatic.

## Ref-as-prop

In React 19, `ref` is a normal prop. No `forwardRef`. Already covered in SKILL.md and `components-and-props.md`, but
worth restating because the consequence is bigger than it looks:

- Component libraries built on `forwardRef` work fine but are now legacy patterns.
- New components type `ref?: React.Ref<HTMLElement>` directly in the props interface.
- `useImperativeHandle` still exists; it pairs with `ref` as a prop the same way it paired with `forwardRef`.

```tsx
interface InputProps extends React.ComponentPropsWithoutRef<"input"> {
    readonly ref?: React.Ref<HTMLInputElement>;
}

export function Input(props: InputProps): React.ReactNode {
    return <input {...props} />;
}
```

## `<Activity>` (React 19.2) — hide and restore without unmount

The `<Activity>` component preserves a tree's state when it is hidden (mode="hidden") and restores it when it is shown
again. Replaces the `display: none` + manual state preservation pattern.

```tsx
import { Activity } from "react";

function Tabs({ activeTab }: { readonly activeTab: "a" | "b" }) {
    return (
        <>
            <Activity mode={activeTab === "a" ? "visible" : "hidden"}>
                <TabA />
            </Activity>
            <Activity mode={activeTab === "b" ? "visible" : "hidden"}>
                <TabB />
            </Activity>
        </>
    );
}
```

When `mode="hidden"`:

- The tree is rendered to a hidden container; effects are torn down (or paused, depending on configuration).
- State and component identities are preserved.
- Re-visibility restores the tree without re-mounting.

Use cases: tabs, modals that should preserve state when closed, lists that page in and out, "previously visited" page
caching in client-side routers.

This is a notable performance and UX primitive — code that previously tracked "which tab was visited" with manual state
can drop that complexity entirely.

## Document Metadata

React 19 hoists `<title>`, `<meta>`, and `<link>` from anywhere in the tree to `<head>` automatically:

```tsx
function PostPage({ post }: { readonly post: Post }) {
    return (
        <article>
            <title>{post.title}</title>
            <meta name="description" content={post.excerpt} />
            <link
                rel="canonical"
                href={`https://example.com/posts/${post.slug}`}
            />
            <h1>{post.title}</h1>
            <p>{post.body}</p>
        </article>
    );
}
```

No `react-helmet`, no `next/head` plumbing required for the common cases. Metadata libraries (Next.js's
`generateMetadata`, TanStack Router's `head` config) are still appropriate when you want type-safe meta or
framework-driven pre-rendering.

## Stylesheets and async scripts

React 19 understands `<link rel="stylesheet">` and `<script async>` in render and de-duplicates them. You can render a
stylesheet conditionally and trust React to load it once.

```tsx
function CodeBlock({ code, lang }: Props) {
    return (
        <>
            <link rel="stylesheet" href="/highlight.css" precedence="default" />
            <pre>
                <code className={`language-${lang}`}>{code}</code>
            </pre>
        </>
    );
}
```

`precedence` controls insertion order. `precedence="default"` is the most common; use the same key across multiple
components that share a stylesheet.

## Async error handling: `onCaughtError`, `onUncaughtError`, `onRecoverableError`

`createRoot` accepts callbacks for the three error pathways:

```ts
import { createRoot } from "react-dom/client";

const root = createRoot(document.getElementById("root")!, {
  onCaughtError: (error, errorInfo) => logToTelemetry("caught", error, errorInfo),
  onUncaughtError: (error, errorInfo) => logToTelemetry("uncaught", error, errorInfo),
  onRecoverableError: (error, errorInfo) => logToTelemetry("recoverable", error, errorInfo),
});
root.render(<App />);
```

Use this in addition to error boundaries, not instead of them. Error boundaries render fallback UI; the root callbacks
observe for logging.

## What was removed in React 19

- **`propTypes`** runtime validation — types-only. Move runtime validation to schema libraries (Zod et al.) or to
  TypeScript at compile time.
- **`defaultProps` on function components** — set defaults in destructuring (`{ variant = "primary" }`).
- **String refs** — use the callback ref or `useRef` form.
- **Legacy Context (`contextTypes`, `childContextTypes`)** — use the modern Context API.
- **`React.createFactory`** — use JSX.

If a third-party library still uses these, it is on borrowed time. New code should not.

## React 19 migration notes

For a codebase migrating from React 18:

1. Upgrade `react` and `react-dom` to 19.x. `npx types-react-codemod` handles many of the type changes.
2. Replace `React.FC` if you still have it.
3. Migrate `forwardRef` opportunistically (no rush — old code keeps working).
4. Replace `useContext` with `use(Context)` opportunistically.
5. Adopt Actions + `useActionState` for new forms; old forms can keep working.
6. Adopt Document Metadata, stylesheet precedence, async scripts where useful.
7. Enable the React Compiler. Adopt the `"use memo"` directive for incremental opt-in if a global flip is too risky.
   Strip preemptive `useMemo` / `useCallback` / `React.memo` once the Compiler is on.
8. Move data fetching out of `useEffect` toward TanStack Query or Server Components / `use()`.

The migration is largely additive — React 19 keeps almost everything React 18 had. The win is in the new patterns making
old patterns obsolete, not in the old patterns being broken.
