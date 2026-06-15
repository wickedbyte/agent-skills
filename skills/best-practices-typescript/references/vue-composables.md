# Vue Composables

Conventions for Vue 3 composables. They apply to Vue 3.x (including Vue 3.5+ reactivity refactors) and to the equivalent
shape in Nuxt 3/4.

A composable encapsulates **a single piece of reactive state and its associated behavior**. Same principles as a small
focused service: clear name, narrow public surface, named exports.

## Naming: `use<Domain>` or `use<Behavior>`

```ts
// ✅ The name describes what is being managed
useDarkMode();
usePostFilters();
useScrollPosition();
useLocalStorage();
useFeatureFlag();

// ❌ Pattern-named or vague
useState();
useHelper();
useComposable();
useData();
```

The `use` prefix is the convention; the suffix is a domain noun or a behavior verb.

## Structure: small returned surface, `as const`

A composable returns a plain object containing only the refs and methods callers should touch. Do not return internal
state.

```ts
// ✅ Focused, explicit surface
import { ref } from "vue";

export function useDarkMode() {
    const isDark = ref<boolean>(false);

    function init(): void {
        isDark.value = window.matchMedia(
            "(prefers-color-scheme: dark)",
        ).matches;
    }

    function toggle(): void {
        isDark.value = !isDark.value;
        document.documentElement.setAttribute(
            "data-theme",
            isDark.value ? "dark" : "light",
        );
    }

    return { isDark, init, toggle } as const;
}
```

`as const` does two things: it freezes the returned shape at the type level (no accidental rebinding from callers) and
signals that the surface is stable.

```ts
// ❌ Junior: exposes internal implementation details
export function useDarkMode() {
    const isDark = ref(false);
    const listeners = ref([]); // internal
    const lastToggleTime = ref<Date | null>(null); // internal

    // ...

    return { isDark, listeners, lastToggleTime, toggle };
    // Callers now depend on internal state they should not touch.
}
```

## Method names are imperative verbs

```ts
// ✅ Verbs that describe the action
return { isDark, init, toggle } as const;
return { posts, load, refresh, clear } as const;
return { position, reset, scrollTo } as const;

// ❌ Vague or noun-based
return { isDark, setup, handleDarkMode } as const;
return { posts, getData, doRefresh } as const;
```

## `init()` for side effects on mount

When a composable needs to read from the DOM, `window`, or any external source on first use, expose that as an explicit
`init()` function rather than running eagerly inside the composable body. Eager side effects break SSR, surprise tests,
and make the composable harder to compose.

```ts
// ✅ init() is called explicitly by the component
import { onMounted } from "vue";

const { isDark, init, toggle } = useDarkMode();
onMounted(() => init());
```

```ts
// ❌ Side effect runs immediately inside the composable
export function useDarkMode() {
    const isDark = ref(
        window.matchMedia("(prefers-color-scheme: dark)").matches, // throws in SSR
    );
    // ...
}
```

Variants on the same idea:

- A composable that needs cleanup on unmount uses `onUnmounted(() => cleanup())` inside the composable body — that is
  reactive lifecycle plumbing, not external state, so it is fine there.
- A composable that wires an event listener exposes `start()` and `stop()` rather than starting eagerly.

## Typing the return value

For most cases the inferred return type is fine. When the composable is part of a stable public API (a library, a shared
package), name the return type:

```ts
import type { Ref } from "vue";

export interface UseDarkMode {
    readonly isDark: Ref<boolean>;
    readonly init: () => void;
    readonly toggle: () => void;
}

export function useDarkMode(): UseDarkMode {
    const isDark = ref<boolean>(false);
    function init(): void {
        /* ... */
    }
    function toggle(): void {
        /* ... */
    }
    return { isDark, init, toggle } as const;
}
```

This is overkill for app-internal composables. Use the inferred type unless you specifically need the contract.

## Argument shape

Compose with a single options object once you have more than two arguments. Otherwise positional arguments are fine.

```ts
// ✅ Two args, positional
export function useLocalStorage<T>(key: string, defaultValue: T) {
    /* ... */
}

// ✅ Options object once it grows
export function useFeatureFlag(options: {
    readonly key: string;
    readonly fallback?: boolean;
    readonly poll?: { intervalMs: number };
}) {
    /* ... */
}
```

For options objects, make every field that has a default `?` optional in the type.

## Reactivity choices

- Use `ref<T>` for single primitives or single references. Access through `.value`.
- Use `reactive<T>` for object state where callers will read properties without `.value`. Be aware that destructuring a
  `reactive` object breaks reactivity — `toRefs()` undoes that for safe destructuring.
- Use `computed<T>` for derived values. Pass a setter when you need a writable computed; otherwise it is read-only and
  tracks dependencies automatically.
- Use `watch` / `watchEffect` for side effects in response to changes. Provide `{ immediate: true }` only when you
  specifically want the effect to fire at mount time.
- For collections, prefer `ref<readonly T[]>` and replace the array (`xs.value = [...xs.value, item]`) over mutating it
  in place — it composes better with `computed` and is friendlier to Vue 3's proxy-based reactivity.

## SSR considerations

Anything that touches `window`, `document`, `localStorage`, `navigator`, or browser-only APIs:

- Move into `init()` (or `onMounted()`).
- Or guard with `typeof window !== "undefined"`.
- Or use Nuxt's `import.meta.client` / `import.meta.server` checks.

State that has to be hydrated from the server (initial dark-mode preference, user identity) should accept a
`ssrFallback` value or be initialized from a server-supplied prop, not read eagerly from `window`.

## Testing composables

Composables with a small, explicit surface are trivial to test. Mount a tiny harness component or use `@vue/test-utils`
`withSetup`:

```ts
import { mount } from "@vue/test-utils";
import { useDarkMode } from "../use-dark-mode.js";

test("toggles theme", () => {
    const wrapper = mount({
        setup() {
            return useDarkMode();
        },
        template: "<div :data-dark='isDark' />",
    });
    // exercise via wrapper.vm
});
```

The composable should be testable **without mounting**, because its public surface is just refs and methods. If your
composable can only be tested by mounting and inspecting DOM side effects, the surface is too tangled — extract the pure
logic into a non-composable function.
