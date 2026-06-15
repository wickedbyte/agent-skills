# Forms

React 19 Actions for the common case, react-hook-form + Zod for client-heavy forms, and the event/input typing patterns
that apply to both.

## Decision: which form library?

| Situation                                                                                     | Default                                                                       |
| --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Simple form (signup, comment, single CRUD operation)                                          | **React 19 Action + `useActionState`**                                        |
| Mutation that should optimistically update UI                                                 | **React 19 Action + `useOptimistic`** + `useFormStatus`                       |
| Complex client-side validation, multi-step, dynamic field arrays, fine-grained dirty tracking | **react-hook-form** + **Zod / Valibot / ArkType** resolver                    |
| Generated forms from a schema                                                                 | **react-hook-form** + a schema-driven adapter                                 |
| Server-render-only form with no client interactivity                                          | A plain `<form action={serverAction}>` in a Server Component, no client hooks |

If both pull, pick React 19 Actions — they are the platform's primitive. react-hook-form is for when you genuinely need
its features.

## React 19 Actions

A Server Action (or any async function) handles a form submission. React tracks pending state, errors, and the returned
state for you.

```tsx
// app/posts/new/page.tsx (server component)
import { CreatePostForm } from "./create-post-form.js";
export default function NewPostPage() {
    return <CreatePostForm />;
}
```

```tsx
// app/posts/new/create-post-form.tsx
"use client";

import { useActionState } from "react";
import { createPost } from "./actions.js";

interface FormState {
    readonly error: string | null;
}
const initialState: FormState = { error: null };

export function CreatePostForm() {
    const [state, formAction, isPending] = useActionState(
        createPost,
        initialState,
    );
    return (
        <form action={formAction} className="space-y-4">
            <label className="block">
                <span>Title</span>
                <input
                    name="title"
                    required
                    className="block w-full rounded border px-3 py-2"
                />
            </label>
            <label className="block">
                <span>Body</span>
                <textarea
                    name="body"
                    required
                    className="block w-full rounded border px-3 py-2"
                    rows={6}
                />
            </label>
            {state.error !== null && (
                <p role="alert" className="text-red-600">
                    {state.error}
                </p>
            )}
            <button
                type="submit"
                disabled={isPending}
                className="rounded bg-blue-600 px-4 py-2 text-white disabled:opacity-50"
            >
                {isPending ? "Saving…" : "Save"}
            </button>
        </form>
    );
}
```

```ts
// app/posts/new/actions.ts
"use server";

import { z } from "zod";
import { redirect } from "next/navigation";

const Input = z.object({
    title: z.string().min(1).max(120),
    body: z.string().min(1),
});

interface FormState {
    readonly error: string | null;
}

export async function createPost(
    prev: FormState,
    formData: FormData,
): Promise<FormState> {
    const parsed = Input.safeParse(Object.fromEntries(formData));
    if (!parsed.success) {
        return { error: parsed.error.issues.map((i) => i.message).join("; ") };
    }
    try {
        const post = await db.posts.insert(parsed.data);
        redirect(`/posts/${post.id}`);
    } catch (err) {
        return { error: err instanceof Error ? err.message : "Unknown error" };
    }
}
```

The Action signature is `(previousState, formData) => Promise<newState>`. React invokes it on submission, passes the
previous state, captures the resulting state, and re-renders.

### Field-level errors

A flat `error: string | null` is fine for simple forms. For field-level errors, return a shape that the UI can read per
field:

```ts
interface FormState {
    readonly errors: {
        readonly title?: string;
        readonly body?: string;
        readonly form?: string;
    };
    readonly values: {
        readonly title?: string;
        readonly body?: string;
    };
}
```

Return the submitted values too so the form preserves user input on validation failure.

### `useFormStatus`

Reads the parent form's submission state. Useful for spinner/disabled state on a submit button that is decoupled from
the form's owner:

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
        <button
            type="submit"
            disabled={pending}
            className="rounded bg-blue-600 px-4 py-2 text-white disabled:opacity-50"
        >
            {pending ? "Saving…" : children}
        </button>
    );
}
```

Always use `useFormStatus` from inside a child of the `<form>` — it discovers the parent via React's internal mechanism,
not via props.

### `useOptimistic` for optimistic mutations

```tsx
"use client";
import { useOptimistic } from "react";
import { addComment } from "./actions.js";

interface Comment {
    readonly id: string;
    readonly body: string;
    readonly pending?: boolean;
}

export function Comments({
    comments,
}: {
    readonly comments: readonly Comment[];
}) {
    const [optimisticComments, addOptimistic] = useOptimistic(
        comments,
        (state, next: Comment) => [...state, { ...next, pending: true }],
    );

    async function action(formData: FormData): Promise<void> {
        const body = formData.get("body");
        if (typeof body !== "string" || body.length === 0) return;
        addOptimistic({ id: crypto.randomUUID(), body });
        await addComment(body);
    }

    return (
        <>
            <ul>
                {optimisticComments.map((c) => (
                    <li
                        key={c.id}
                        className={c.pending === true ? "opacity-50" : ""}
                    >
                        {c.body}
                    </li>
                ))}
            </ul>
            <form action={action}>
                <input name="body" required />
                <button type="submit">Post</button>
            </form>
        </>
    );
}
```

The optimistic state automatically reverts if the server-state update does not include the optimistic change.

## react-hook-form + Zod

For complex client-heavy forms, react-hook-form (v7.66+) is the dominant choice. It uses uncontrolled inputs by
default (registering them with `register(...)`), which keeps re-renders minimal.

```tsx
"use client";

import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";

const Schema = z.object({
    title: z.string().min(1, "Title is required").max(120),
    body: z.string().min(1, "Body is required"),
    tags: z.array(z.string()).min(1, "At least one tag"),
    publishedAt: z.string().datetime().optional(),
});

type FormValues = z.infer<typeof Schema>;

export function PostEditForm({
    post,
    onSubmit,
}: {
    readonly post: Post;
    readonly onSubmit: (values: FormValues) => Promise<void>;
}) {
    const form = useForm<FormValues>({
        resolver: zodResolver(Schema),
        defaultValues: {
            title: post.title,
            body: post.body,
            tags: post.tags,
            publishedAt: post.publishedAt ?? undefined,
        },
    });
    const {
        register,
        handleSubmit,
        formState: { errors, isSubmitting, isDirty },
    } = form;

    return (
        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
            <label className="block">
                Title
                <input
                    {...register("title")}
                    className="block w-full rounded border px-3 py-2"
                />
                {errors.title !== undefined && (
                    <span role="alert">{errors.title.message}</span>
                )}
            </label>

            <label className="block">
                Body
                <textarea
                    {...register("body")}
                    className="block w-full rounded border px-3 py-2"
                    rows={8}
                />
                {errors.body !== undefined && (
                    <span role="alert">{errors.body.message}</span>
                )}
            </label>

            <button type="submit" disabled={isSubmitting || !isDirty}>
                {isSubmitting ? "Saving…" : "Save"}
            </button>
        </form>
    );
}
```

Key patterns:

- **One Zod schema drives types and validation.** `z.infer<typeof Schema>` becomes the `FormValues` type. The same
  schema validates client-side and (re-used) server-side.
- **`register("name")` for simple inputs.** For controlled components (Radix, MUI, third-party), use `Controller`.
- **`useFieldArray` for dynamic arrays.** Common for tag lists, address books, repeating sections.
- **`isDirty`, `dirtyFields`, `isSubmitting`** — fine-grained form state without manual tracking.

### Controlled inputs with `Controller`

```tsx
import { Controller } from "react-hook-form";
import { Select } from "@radix-ui/react-select";

<Controller
    name="status"
    control={form.control}
    render={({ field }) => (
        <Select value={field.value} onValueChange={field.onChange}>
            ...
        </Select>
    )}
/>;
```

### Field arrays

```tsx
import { useFieldArray } from "react-hook-form";

const { fields, append, remove } = useFieldArray({
    control: form.control,
    name: "tags",
});

return (
    <>
        {fields.map((field, index) => (
            <div key={field.id}>
                <input {...form.register(`tags.${index}.value`)} />
                <button type="button" onClick={() => remove(index)}>
                    Remove
                </button>
            </div>
        ))}
        <button type="button" onClick={() => append({ value: "" })}>
            Add tag
        </button>
    </>
);
```

`field.id` (not `index`) for the key — react-hook-form assigns stable IDs.

## Event typing

```tsx
function onClick(event: React.MouseEvent<HTMLButtonElement>): void { ... }
function onChange(event: React.ChangeEvent<HTMLInputElement>): void { setValue(event.target.value); }
function onSubmit(event: React.FormEvent<HTMLFormElement>): void { event.preventDefault(); ... }
function onKeyDown(event: React.KeyboardEvent<HTMLInputElement>): void { if (event.key === "Enter") ... }
function onBlur(event: React.FocusEvent<HTMLInputElement>): void { ... }
function onPaste(event: React.ClipboardEvent<HTMLTextAreaElement>): void { ... }
function onDrop(event: React.DragEvent<HTMLDivElement>): void { ... }
```

The pattern is `React.<Kind>Event<HTMLElementType>`. Avoid `any`. Avoid `as HTMLInputElement` casts — type the handler
correctly and `event.currentTarget` / `event.target` are already typed.

### `currentTarget` vs. `target`

- `event.currentTarget` is typed as the element the handler is attached to — usually what you want.
- `event.target` can be a descendant inside the element (e.g., a click on a `<span>` inside a `<button>`); its type is
  `EventTarget`, which is wider.

```tsx
<button
    onClick={(e) => {
        e.currentTarget.disabled = true; // typed as HTMLButtonElement
        e.target; // EventTarget — needs narrowing
    }}
/>
```

## Controlled vs. uncontrolled inputs

|                          | Controlled                                                              | Uncontrolled                                      |
| ------------------------ | ----------------------------------------------------------------------- | ------------------------------------------------- |
| State source             | React state                                                             | The DOM element itself                            |
| Pattern                  | `value={...}` + `onChange={...}`                                        | `defaultValue={...}` + read via ref / form submit |
| Re-renders per keystroke | Yes                                                                     | No                                                |
| Right for                | Inputs whose value is read frequently during typing, conditional fields | Forms read only on submit                         |
| Library                  | Plain React, MUI, Radix Form                                            | react-hook-form (default), HTML `<form>`          |

Both are valid. The choice is about **whether you need React state for the value during typing**. A search box that
filters live? Controlled. A 12-field profile form submitted on save? Uncontrolled (react-hook-form) is much cheaper.

## File uploads

```tsx
<form action={uploadAction} encType="multipart/form-data">
    <input type="file" name="file" required />
    <button type="submit">Upload</button>
</form>
```

```ts
"use server";

export async function uploadAction(
    prev: State,
    formData: FormData,
): Promise<State> {
    const file = formData.get("file");
    if (!(file instanceof File)) return { error: "No file" };
    const buffer = Buffer.from(await file.arrayBuffer());
    await storage.put(file.name, buffer);
    return { error: null };
}
```

Watch for size limits (framework / platform impose them), MIME validation, virus scanning if untrusted.

## Common mistakes

| Mistake                                                                    | Fix                                                                                                         |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `e: any` on handlers                                                       | `React.ChangeEvent<HTMLInputElement>` etc.                                                                  |
| `as HTMLInputElement` on `event.target`                                    | Type the handler correctly; read `event.currentTarget`                                                      |
| Putting form state in Zustand / Redux                                      | Local `useState` / react-hook-form                                                                          |
| Re-validating with a separate Zod call after submit                        | Use `useActionState` (server-side parse) or `zodResolver` (client-side); single source of truth             |
| Manual `isLoading` tracking around an async submission                     | `useActionState`'s `isPending`, or react-hook-form's `formState.isSubmitting`                               |
| Calling `useFormStatus` outside a `<form>`                                 | It must be a descendant of the form                                                                         |
| `useOptimistic` without a server mutation that updates the canonical state | The optimistic value will not roll back; double-check the data flow                                         |
| `defaultValue` and `value` both set on the same input                      | Pick one — controlled (`value`) or uncontrolled (`defaultValue`)                                            |
| Forgetting `event.preventDefault()` in a manually-handled `onSubmit`       | Form does a full-page POST; with React 19 Actions you do not need to call preventDefault — React handles it |
