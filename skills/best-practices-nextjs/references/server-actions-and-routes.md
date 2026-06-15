# Server Actions, Route Handlers & proxy.ts

How to do mutations, forms, HTTP endpoints, and request interception idiomatically and securely in Next.js 16.

## Contents

- Server Actions vs Route Handlers — which to use
- Writing Server Actions
- Forms with `useActionState` and `useFormStatus`
- Validation with Zod
- Security: treat actions as public endpoints
- Route Handlers (`route.ts`)
- `proxy.ts` (formerly `middleware.ts`)
- Common mistakes

## Server Actions vs Route Handlers — which to use

- **Server Actions** (`'use server'` functions): the default for **mutations** (create/update/delete), form submissions,
  and any server logic triggered by your own UI. No API boilerplate, type-safe call from components, integrate with
  caching APIs. POST-only, not cacheable — **not for reading data**.
- **Route Handlers** (`app/api/**/route.ts`): for **public/external HTTP endpoints** consumed by third parties,
  webhooks, OAuth callbacks, or when you need full control over the HTTP request/response (custom methods, headers,
  streaming, non-browser clients). Also the way Client Components reach the backend when a Server Action doesn't fit.
- **Reads** generally happen in Server Components (see `components-and-data.md`), not in either of these.

## Writing Server Actions

Mark a function (or a whole file) with `'use server'`. A file of actions can be imported by both Server and Client
Components.

```ts
// app/posts/actions.ts
"use server";

import { z } from "zod";
import { revalidateTag, updateTag } from "next/cache";
import { auth } from "@/lib/auth";

const CreatePost = z.object({
    title: z.string().min(1).max(200),
    body: z.string().min(1),
});

export type ActionResult =
    | { ok: true }
    | { ok: false; formError?: string; fieldErrors?: Record<string, string[]> };

export async function createPost(
    _prev: ActionResult,
    formData: FormData,
): Promise<ActionResult> {
    // 1. AUTHENTICATE — actions are public endpoints
    const session = await auth();
    if (!session) return { ok: false, formError: "Not authenticated" };

    // 2. VALIDATE on the server (never trust the client)
    const parsed = CreatePost.safeParse({
        title: formData.get("title"),
        body: formData.get("body"),
    });
    if (!parsed.success) {
        return { ok: false, fieldErrors: parsed.error.flatten().fieldErrors };
    }

    // 3. AUTHORIZE + mutate
    await db.posts.create({ ...parsed.data, authorId: session.userId });

    // 4. INVALIDATE cache so the UI reflects the change
    updateTag(`user-${session.userId}-posts`); // read-your-writes
    return { ok: true };
}
```

Return typed result objects for **expected** failures (validation, auth) rather than throwing; reserve thrown errors for
truly exceptional cases caught by an `error.tsx` boundary.

## Forms with `useActionState` and `useFormStatus`

React 19's `useActionState` (from `react`, replacing the old `useFormState` from `react-dom`) is the recommended form
pattern. It wires an action to form state with built-in pending/error handling:

```tsx
"use client";
import { useActionState } from "react";
import { createPost, type ActionResult } from "./actions";

const initial: ActionResult = { ok: false };

export function NewPostForm() {
    const [state, formAction, isPending] = useActionState(createPost, initial);
    return (
        <form action={formAction}>
            <input name="title" />
            {!state.ok && state.fieldErrors?.title && (
                <p role="alert">{state.fieldErrors.title.join(", ")}</p>
            )}
            <textarea name="body" />
            <SubmitButton />
            {!state.ok && state.formError && (
                <p role="alert">{state.formError}</p>
            )}
        </form>
    );
}
```

For the submit button's pending state, use `useFormStatus` (from `react-dom`) in a child of the `<form>`:

```tsx
"use client";
import { useFormStatus } from "react-dom";
function SubmitButton() {
    const { pending } = useFormStatus();
    return <button disabled={pending}>{pending ? "Saving…" : "Save"}</button>;
}
```

- Use `useActionState` when you need the action result and form-level state.
- Use `useFormStatus` for a simple pending indicator inside the form.
- Forms can call actions directly via `<form action={serverAction}>` without JS, and progressively enhance.

## Validation with Zod

Define one Zod schema and reuse it. Validate on the **server** in the action regardless of any client-side checks (
client validation is UX, not security). Return `flatten().fieldErrors` for friendly per-field messages.

## Security: treat actions as public endpoints

A Server Action compiles to a public HTTP POST endpoint. Anyone can invoke it with arbitrary input. Therefore every
action must:

1. **Authenticate** the caller (check the session).
2. **Validate** all inputs server-side (Zod).
3. **Authorize** — confirm this user may perform this action on this resource (not just that they're logged in).
4. Consider **rate limiting** for sensitive or expensive actions.
5. Never rely on the client having hidden a button or validated input.

The same applies to Route Handlers.

## Route Handlers (`route.ts`)

Export functions named for HTTP methods. Cannot coexist with `page.tsx` in the same segment.

```ts
// app/api/posts/route.ts
import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

export async function GET(req: NextRequest) {
    const { searchParams } = req.nextUrl;
    const limit = Number(searchParams.get("limit") ?? 20);
    const posts = await db.posts.list({ limit });
    return NextResponse.json(posts);
}

export async function POST(req: NextRequest) {
    const body = await req.json();
    const parsed = CreatePost.safeParse(body);
    if (!parsed.success) {
        return NextResponse.json(
            { errors: parsed.error.flatten() },
            { status: 400 },
        );
    }
    // authenticate + authorize, then mutate...
    const created = await db.posts.create(parsed.data);
    return NextResponse.json(created, { status: 201 });
}
```

- Dynamic params come from the second arg and are **async** in v16:
  `({ params }: { params: Promise<{ id: string }> })` → `const { id } = await params`.
- Route Handlers are dynamic by default; cache explicitly with `"use cache"` semantics where appropriate.
- Use for webhooks (verify signatures), OAuth callbacks, and external API surface — not for internal mutations that a
  Server Action handles more simply.

## `proxy.ts` (formerly `middleware.ts`)

v16 renames `middleware.ts` → **`proxy.ts`**, with an exported `proxy` function running on the **Node.js** runtime. The
logic is the same; the rename clarifies that this is the network boundary for request interception.

```ts
// proxy.ts (project root, or src/)
import { NextRequest, NextResponse } from "next/server";

export default function proxy(request: NextRequest) {
    const session = request.cookies.get("session");
    if (!session && request.nextUrl.pathname.startsWith("/dashboard")) {
        return NextResponse.redirect(new URL("/login", request.url));
    }
    return NextResponse.next();
}

export const config = {
    matcher: ["/dashboard/:path*"],
};
```

- Migration: rename the file and the exported function to `proxy`; logic is unchanged. `middleware.ts` still works for
  Edge-runtime cases but is **deprecated**.
- Use `proxy.ts` for lightweight concerns: redirects, rewrites, auth gating at the edge of routing, setting
  headers/cookies. Keep heavy logic out of it.

## Common mistakes

- Using a Server Action to fetch/read data (it's POST-only and uncacheable → use a Server Component).
- Trusting client-side validation for security — always re-validate and authorize on the server.
- Forgetting that actions/handlers are publicly callable; skipping auth/authorization.
- Creating a Route Handler for a simple internal form mutation that a Server Action handles with less code.
- Forgetting `params` is async in Route Handlers in v16.
- Leaving `middleware.ts` in a new v16 project instead of `proxy.ts`.
- Not invalidating cache after a mutation (`updateTag`/`revalidateTag`/`refresh`), so the UI shows stale data.
