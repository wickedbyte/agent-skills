# Styling

Tailwind 4 (Oxide engine) is the default for React apps in 2026. `cn()` composition, Radix primitives, shadcn-style
component ownership. Alternatives covered briefly.

## Tailwind 4 setup

Tailwind 4 ships with the Oxide engine — Rust-based, ~10x faster, zero-config defaults, native CSS variable theming. The
setup is simpler than v3.

```css
/* app/globals.css */
@import "tailwindcss";

/* Optional: customize the theme via CSS variables */
@theme {
    --color-brand-50: oklch(98% 0.02 250);
    --color-brand-500: oklch(60% 0.18 250);
    --color-brand-900: oklch(30% 0.1 250);
    --font-display: "Inter", system-ui, sans-serif;
}
```

PostCSS plugin (when not using a Tailwind-native bundler integration):

```js
// postcss.config.mjs
export default {
    plugins: {
        "@tailwindcss/postcss": {},
    },
};
```

`autoprefixer` and `postcss-import` are no longer needed — Tailwind 4 handles vendor prefixing and imports.

### Vite / Next.js integration

For Vite, use the Tailwind Vite plugin:

```ts
// vite.config.ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
    plugins: [react(), tailwindcss()],
});
```

For Next.js 16, follow the Tailwind docs (the integration is typically via the PostCSS plugin or a Next-specific
helper).

### The Tailwind config — usually nothing

In Tailwind 4 most configuration moves into CSS via `@theme`. A `tailwind.config.ts` file is rarely needed. When you do
need it (custom plugins, complex content paths), it is still supported.

## `cn()` — the composition primitive

```ts
// lib/cn.ts
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]): string {
    return twMerge(clsx(inputs));
}
```

- `clsx` joins conditional class lists cleanly.
- `tailwind-merge` resolves _Tailwind-specific_ conflicts so the last conflicting class wins. Without it,
  `cn("px-4", "px-8")` produces `"px-4 px-8"` and the browser cascade wins by source order — fragile.

Usage:

```tsx
<button
    className={cn(
        "inline-flex items-center justify-center rounded-md font-medium",
        "transition-colors focus-visible:ring-2 focus-visible:ring-blue-500",
        size === "sm" && "h-8 px-3 text-sm",
        size === "md" && "h-10 px-4",
        size === "lg" && "h-12 px-6 text-lg",
        variant === "primary" && "bg-blue-600 text-white hover:bg-blue-700",
        variant === "ghost" && "bg-transparent text-blue-600 hover:bg-blue-50",
        disabled && "opacity-50 cursor-not-allowed",
        className, // caller override always last → wins
    )}
    {...rest}
/>
```

The pattern:

1. Static base classes first.
2. Variant-driven classes via `&&`.
3. Caller-provided `className` last so it can override anything.

## `class-variance-authority` (CVA) for component variant systems

For components with several orthogonal variants (size × variant × state), CVA is the structured form of the same
composition:

```tsx
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/cn.js";

const buttonStyles = cva(
    "inline-flex items-center justify-center rounded-md font-medium transition-colors focus-visible:ring-2 focus-visible:ring-blue-500",
    {
        variants: {
            variant: {
                primary: "bg-blue-600 text-white hover:bg-blue-700",
                secondary: "bg-gray-200 text-gray-900 hover:bg-gray-300",
                ghost: "bg-transparent text-blue-600 hover:bg-blue-50",
            },
            size: {
                sm: "h-8 px-3 text-sm",
                md: "h-10 px-4",
                lg: "h-12 px-6 text-lg",
            },
        },
        defaultVariants: { variant: "primary", size: "md" },
    },
);

interface ButtonProps
    extends
        React.ComponentPropsWithoutRef<"button">,
        VariantProps<typeof buttonStyles> {
    readonly ref?: React.Ref<HTMLButtonElement>;
}

export function Button({
    variant,
    size,
    className,
    ref,
    ...rest
}: ButtonProps): React.ReactNode {
    return (
        <button
            ref={ref}
            className={cn(buttonStyles({ variant, size }), className)}
            {...rest}
        />
    );
}
```

CVA gives you:

- A typed `VariantProps<typeof buttonStyles>` that flows into the component's props.
- Default variants.
- Compound variants (`compoundVariants` — apply classes only when _two_ variants combine in a specific way).

Use CVA on shared design-system components (Button, Input, Badge, Card). For one-off components with one or two
conditional classes, plain `cn()` is enough.

## Radix UI primitives

Radix gives you accessible, unstyled headless primitives (Dialog, Popover, Select, Tabs, Switch, ...). You bring the
styles.

```tsx
import * as Dialog from "@radix-ui/react-dialog";

export function ConfirmDialog({
    open,
    onOpenChange,
    onConfirm,
    children,
}: Props) {
    return (
        <Dialog.Root open={open} onOpenChange={onOpenChange}>
            <Dialog.Portal>
                <Dialog.Overlay className="fixed inset-0 bg-black/50" />
                <Dialog.Content className="fixed left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 rounded-lg bg-white p-6 shadow-xl">
                    <Dialog.Title className="text-lg font-semibold">
                        Confirm
                    </Dialog.Title>
                    <Dialog.Description className="mt-2 text-sm text-gray-600">
                        {children}
                    </Dialog.Description>
                    <div className="mt-4 flex justify-end gap-2">
                        <Dialog.Close asChild>
                            <Button variant="ghost">Cancel</Button>
                        </Dialog.Close>
                        <Button variant="primary" onClick={onConfirm}>
                            Confirm
                        </Button>
                    </div>
                </Dialog.Content>
            </Dialog.Portal>
        </Dialog.Root>
    );
}
```

Radix handles focus management, keyboard navigation, aria attributes, portaling, scroll locking. You handle the look.

The `asChild` pattern (Radix `Slot`) lets you compose Radix's behavior into any element you bring — that is how
`shadcn/ui` builds its components.

## shadcn/ui — own the components

shadcn/ui is not a library installed via npm. It is a CLI that copies fully-styled, Radix-based component files into
your repo. You own and modify them.

```bash
npx shadcn@latest add button
npx shadcn@latest add dialog
```

This puts `components/ui/button.tsx`, `components/ui/dialog.tsx` etc. into your repo. Edit them like any other source
file.

The pattern:

- A `components/ui/` directory holds the primitive components (Button, Input, Dialog, ...).
- Application components in `components/` compose them.
- Updating a primitive (e.g., the Button's variant set) changes every usage with no version-bump dance.

This is the dominant React component story in 2026.

## Dark mode

The modern pattern uses CSS variables and a `data-theme` (or `class="dark"`) attribute on the root. Tailwind 4 supports
`dark:` variants out of the box.

```tsx
// app/theme-provider.tsx
"use client";
import { useEffect } from "react";
import { useUIStore } from "@/lib/store.js";

export function ThemeProvider({
    children,
}: {
    readonly children: React.ReactNode;
}) {
    const theme = useUIStore((s) => s.theme);
    useEffect(() => {
        document.documentElement.dataset.theme = theme;
        document.documentElement.classList.toggle("dark", theme === "dark");
    }, [theme]);
    return <>{children}</>;
}
```

```css
@import "tailwindcss";

@theme {
    --color-bg: white;
    --color-fg: black;
}

[data-theme="dark"] {
    --color-bg: #0a0a0a;
    --color-fg: #fafafa;
}
```

For SSR-safe dark mode (no flash), set the `data-theme` attribute server-side from a cookie or `localStorage`-read
script that runs before paint. `next-themes` is the common library; rolling your own is also fine.

## Alternatives to Tailwind

### CSS Modules

For component-local styles, CSS Modules still work:

```tsx
import styles from "./post-card.module.css";
<article className={styles.card}>...</article>;
```

Type-safe via `vite-plugin-dts` or framework integration. Fine for incremental adoption or when Tailwind feels
excessive.

### vanilla-extract

Type-safe zero-runtime CSS-in-TS. Stronger types and theme inference than Tailwind, but a heavier learning curve.

```ts
// post-card.css.ts
import { style } from "@vanilla-extract/css";
export const card = style({ padding: 16, borderRadius: 8 });
```

### Panda CSS

A typesafe CSS-in-JS / utility framework with generated atomic CSS. Combines aspects of Tailwind and vanilla-extract.

### styled-components / Emotion

Runtime CSS-in-JS libraries have lost ground because they do not work well with React Server Components — the runtime
needs to ship to the client. If you have an existing styled-components app, it works; for new code, prefer Tailwind or
vanilla-extract.

### Plain CSS / Sass

Always an option. For small apps or styled-system replacements, plain CSS with custom properties is underrated.

## Common mistakes

| Mistake                                                                              | Fix                                                                  |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| `className={`px-4 ${className}`}` template strings                                   | `cn("px-4", className)`                                              |
| Caller's `className` placed before component's defaults                              | Caller's `className` is last — `cn()` + `tailwind-merge` resolves it |
| Conditional `className={isActive ? "bg-blue-600" : "bg-gray-200"}` for many variants | CVA                                                                  |
| Re-implementing accessible primitives from scratch                                   | Radix + Tailwind (shadcn pattern)                                    |
| `autoprefixer` / `postcss-import` in Tailwind 4 PostCSS config                       | Remove — Tailwind 4 handles both                                     |
| Inline `style={{ color: ... }}` for theming                                          | CSS variables + Tailwind / `data-theme`                              |
| Flash of unstyled / wrong-theme content on first paint                               | Set `data-theme` server-side from cookie / inline script             |
| Runtime CSS-in-JS in a Server Components app                                         | Switch to Tailwind, vanilla-extract, or another zero-runtime story   |
