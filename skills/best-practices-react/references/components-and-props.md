# Components and Props

How to declare components, type their props, expose refs, accept children, and compose variants.

## Declaration form

```tsx
// ✅ Default — function declaration, named export, explicit prop interface
interface PostCardProps {
    readonly post: Post;
    readonly onSelect?: (post: Post) => void;
    readonly className?: string;
}

export function PostCard({
    post,
    onSelect,
    className,
}: PostCardProps): React.ReactNode {
    return (
        <article className={className} onClick={() => onSelect?.(post)}>
            <h2>{post.title}</h2>
            <p>{post.excerpt}</p>
        </article>
    );
}
```

- **`function`, not arrow.** Arrow components work; `function` gives a stable name in stack traces and devtools without
  ceremony.
- **Named export, not default.** Defaults are reserved for framework slots that require them (Next.js route segments,
  `React.lazy()` targets).
- **Props interface, not type alias** (with one exception below). Suffix `Props` is the convention.
- **`readonly` on every field.** Props are immutable by contract.
- **Return type `React.ReactNode`.** Wider than `JSX.Element`, which lets the component return strings, arrays,
  fragments, `null`, etc. Explicit return types are optional but help inference at the public boundary.

When props are discriminated by a variant (the _shape_ of the props depends on the variant), use a `type` union:

```tsx
type ButtonProps =
    | { readonly variant: "link"; readonly href: string }
    | { readonly variant: "button"; readonly onClick: () => void };
```

That is the one case where `type` beats `interface` for props.

## No `React.FC`

`React.FC` / `React.FunctionComponent` typed `children` implicitly, broke generic components, and added nothing. Modern
React code does not use it.

```tsx
// ❌
const PostCard: React.FC<PostCardProps> = ({ post }) => (
    <article>{post.title}</article>
);

// ✅
function PostCard({ post }: PostCardProps): React.ReactNode {
    return <article>{post.title}</article>;
}
```

## Children patterns

```tsx
// ✅ "Anything renderable" — most common
interface CardProps {
    readonly children: React.ReactNode;
}

// ✅ "Exactly one element" — rare, useful for wrappers that need a single child
interface TooltipProps {
    readonly children: React.ReactElement;
    readonly content: string;
}

// ✅ "A render function" — headless / inversion-of-control
interface ListProps<T> {
    readonly items: readonly T[];
    readonly children: (item: T, index: number) => React.ReactNode;
}

// ❌ Deprecated / too narrow
interface BadProps {
    readonly children: React.ReactChild;
} // deprecated alias
interface BadProps {
    readonly children: JSX.Element;
} // too narrow
```

For multiple "named children" slots, use named props rather than parsing children:

```tsx
// ✅ Named slot props — discoverable, type-safe
interface ModalProps {
    readonly title: React.ReactNode;
    readonly body: React.ReactNode;
    readonly footer?: React.ReactNode;
}

// ❌ Slot picking via cloneElement / children.map — fragile, untyped
```

## `ref` is a prop in React 19 — `forwardRef` is dead

```tsx
// ✅ React 19 — ref is a normal prop, types via ComponentProps helpers
interface InputProps extends React.ComponentPropsWithoutRef<"input"> {
    readonly ref?: React.Ref<HTMLInputElement>;
}

export function Input({
    ref,
    className,
    ...rest
}: InputProps): React.ReactNode {
    return (
        <input
            ref={ref}
            className={cn("rounded border px-3 py-2", className)}
            {...rest}
        />
    );
}

// ❌ Pre-React-19 — do not write new code like this
const Input = React.forwardRef<HTMLInputElement, InputProps>(
    ({ className, ...rest }, ref) => (
        <input ref={ref} className={cn("...", className)} {...rest} />
    ),
);
```

If you are touching an old `forwardRef` and have time, migrate. The behavior is identical; the type signatures get
simpler; devtools display the component name without the `ForwardRef(...)` wrapper.

## Extending DOM element props with `ComponentProps`

`React.ComponentPropsWithoutRef<"button">` gives you every prop a `<button>` accepts, including all the event handlers
and `aria-*` / `data-*` attributes.

```tsx
// ✅ A button that adds a variant and accepts every native button prop
interface ButtonProps extends React.ComponentPropsWithoutRef<"button"> {
    readonly variant?: "primary" | "secondary" | "ghost";
    readonly ref?: React.Ref<HTMLButtonElement>;
}

export function Button({
    variant = "primary",
    className,
    ref,
    ...rest
}: ButtonProps): React.ReactNode {
    return (
        <button
            ref={ref}
            className={cn(
                "inline-flex items-center justify-center rounded-md px-4 py-2 font-medium",
                variant === "primary" &&
                    "bg-blue-600 text-white hover:bg-blue-700",
                variant === "secondary" &&
                    "bg-gray-200 text-gray-900 hover:bg-gray-300",
                variant === "ghost" &&
                    "bg-transparent text-blue-600 hover:bg-blue-50",
                className,
            )}
            {...rest}
        />
    );
}
```

Notes:

- `ComponentPropsWithoutRef<"button">` (not `ComponentProps<"button">`) so the `ref` field is yours to redeclare with
  the React 19 shape.
- Spread `{...rest}` last so caller-provided handlers and aria attrs flow through.
- `className` is destructured separately so it can be merged via `cn()`. Spreading `{...rest}` after would let the
  caller's `className` overwrite yours; merging via `cn()` lets both compose.
- For a wrapper around another component (not a DOM element), use `React.ComponentProps<typeof InnerComponent>`.

## Generic components

A component that takes a generic `T` is declared as a regular function with a type parameter. The JSX
`<Foo<string> ... />` syntax works in `.tsx` since TS 4.5+.

```tsx
interface SelectProps<T> {
    readonly options: readonly T[];
    readonly value: T;
    readonly onChange: (next: T) => void;
    readonly getLabel: (option: T) => string;
    readonly getKey: (option: T) => string | number;
}

export function Select<T>({
    options,
    value,
    onChange,
    getLabel,
    getKey,
}: SelectProps<T>): React.ReactNode {
    return (
        <select
            value={getKey(value).toString()}
            onChange={(e) => {
                const next = options.find(
                    (o) => getKey(o).toString() === e.target.value,
                );
                if (next !== undefined) onChange(next);
            }}
        >
            {options.map((option) => (
                <option key={getKey(option)} value={getKey(option).toString()}>
                    {getLabel(option)}
                </option>
            ))}
        </select>
    );
}

// usage — T inferred
<Select
    options={statuses}
    value={status}
    onChange={setStatus}
    getLabel={(s) => s.label}
    getKey={(s) => s.id}
/>;
```

Generic components are how you preserve type information across composition boundaries (lists, selects, tables, query
renderers). Use them when a relationship between props exists.

## Polymorphic components — the `as` prop

Sometimes a component should render different elements ("a button that is sometimes an `<a>`"). The Radix `Slot`
pattern (used by shadcn/ui) is the dominant idiom and avoids the `as` prop's typing complexity:

```tsx
// ✅ Recommended — Slot composes with the child, no polymorphic types
import {Slot} from "@radix-ui/react-slot";

interface ButtonProps extends React.ComponentPropsWithoutRef<"button"> {
    readonly asChild?: boolean;
    readonly variant?: "primary" | "ghost";
}

export function Button({asChild = false, variant = "primary", ...rest}: ButtonProps): React.ReactNode {
    const Component = asChild ? Slot : "button";
    return <Component className={cn(...)} {...rest} />;
}

// usage
<Button>Click me</Button>
<Button asChild><a href="/about">About</a></Button>
```

When you really need a polymorphic `as` with full prop inference for the underlying element, the typing is involved and
several libraries implement it (Radix `Slot`, MUI `OverridableComponent`, Chakra). Prefer `Slot` for new code — it
sidesteps the problem.

## Discriminated unions for variants whose props differ

When the _shape of the props_ depends on the variant, model the props themselves as a discriminated union. The compiler
will refuse invalid combinations.

```tsx
type AlertProps =
    | { readonly variant: "info"; readonly children: React.ReactNode }
    | { readonly variant: "error"; readonly children: React.ReactNode; readonly onRetry: () => void };

export function Alert(props: AlertProps): React.ReactNode {
    switch (props.variant) {
        case "info":
            return <div role="status">{props.children}</div>;
        case "error":
            return (
                <div role="alert">
                    {props.children}
                    <button onClick={props.onRetry}>Retry</button>
                </div>
            );
    }
}

// ❌ rejected at compile time
<Alert variant="info" onRetry={fn}/>        // info has no onRetry
<Alert variant="error">Failed</Alert>         // error requires onRetry
```

Variants whose _props are identical_ (only the visual style changes) do not need this — just a string literal union:

```tsx
interface ButtonProps {
    readonly variant: "primary" | "secondary" | "ghost";
    readonly children: React.ReactNode;
}
```

## Optional vs. required props

- A prop that has a sensible default is `?` and the default is set in destructuring:
  `{ variant = "primary" }: ButtonProps`.
- A prop that the caller _must_ supply is required (no `?`). Do not give it a fallback inside the component and document
  the meaning instead.
- A boolean prop that toggles behavior is `flag?: boolean` and defaults to `false` (or whatever the safe default is).
  Avoid `flag: boolean | undefined`.

```tsx
// ✅
interface DialogProps {
    readonly open: boolean; // required, no sensible default
    readonly onOpenChange: (open: boolean) => void; // required
    readonly modal?: boolean; // optional, defaults to true
    readonly children: React.ReactNode;
}

export function Dialog({
    open,
    onOpenChange,
    modal = true,
    children,
}: DialogProps) {
    // ...
}
```

## Render props and inversion of control

For headless / behavioral components, a render prop (or `children` as a function) gives callers full control over
markup:

```tsx
interface QueryProps<T> {
    readonly queryKey: readonly unknown[];
    readonly queryFn: () => Promise<T>;
    readonly children: (
        state:
            | { status: "loading" }
            | { status: "error"; error: Error }
            | { status: "success"; data: T },
    ) => React.ReactNode;
}

export function Query<T>({ queryKey, queryFn, children }: QueryProps<T>) {
    const query = useQuery({ queryKey, queryFn });
    if (query.isPending) return children({ status: "loading" });
    if (query.isError) return children({ status: "error", error: query.error });
    return children({ status: "success", data: query.data });
}
```

Modern React more often pushes this responsibility into hooks (`useQuery` directly in the component) rather than
render-prop wrappers. Keep render props for genuine inversion-of-control needs (compound components, library APIs).

## Compound components

Components that share state with their children via Context, exposing a small API on a namespace object:

```tsx
interface TabsContextValue {
    readonly value: string;
    readonly setValue: (next: string) => void;
}

const TabsContext = createContext<TabsContextValue | null>(null);

function useTabsContext(): TabsContextValue {
    const ctx = useContext(TabsContext);
    if (ctx === null) throw new Error("Tabs.* must be used inside <Tabs>");
    return ctx;
}

interface TabsRootProps {
    readonly value: string;
    readonly onValueChange: (next: string) => void;
    readonly children: React.ReactNode;
}

function TabsRoot({ value, onValueChange, children }: TabsRootProps) {
    return (
        <TabsContext.Provider value={{ value, setValue: onValueChange }}>
            <div>{children}</div>
        </TabsContext.Provider>
    );
}

function TabsList({ children }: { readonly children: React.ReactNode }) {
    return <div role="tablist">{children}</div>;
}

function TabsTrigger({
    value,
    children,
}: {
    readonly value: string;
    readonly children: React.ReactNode;
}) {
    const ctx = useTabsContext();
    return (
        <button
            role="tab"
            aria-selected={ctx.value === value}
            onClick={() => ctx.setValue(value)}
        >
            {children}
        </button>
    );
}

function TabsContent({
    value,
    children,
}: {
    readonly value: string;
    readonly children: React.ReactNode;
}) {
    const ctx = useTabsContext();
    if (ctx.value !== value) return null;
    return <div role="tabpanel">{children}</div>;
}

export const Tabs = Object.assign(TabsRoot, {
    List: TabsList,
    Trigger: TabsTrigger,
    Content: TabsContent,
});

// usage
<Tabs value={value} onValueChange={setValue}>
    <Tabs.List>
        <Tabs.Trigger value="a">A</Tabs.Trigger>
        <Tabs.Trigger value="b">B</Tabs.Trigger>
    </Tabs.List>
    <Tabs.Content value="a">A content</Tabs.Content>
    <Tabs.Content value="b">B content</Tabs.Content>
</Tabs>;
```

The `Object.assign(Root, { Sub })` pattern is the type-safe way to expose a namespace.

## What about `displayName`?

In React 19 with named function components, devtools picks up the function name automatically. You no longer need to
assign `displayName` for normal components. The exception is anonymously-defined wrappers (e.g., `Object.assign`
namespaces, factory-built components) where the function does not have a name — there,
`Component.displayName = "Tabs.Trigger"` still helps devtools.
