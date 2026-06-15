# Traits and Generics

Small behavior-focused traits, generics (static dispatch) vs. `dyn` (dynamic dispatch), `impl Trait`, the
`From`/`Into`/`TryFrom` family, dyn-compatibility, RPITIT and the `async fn` in traits caveat, associated types, and
sealed/marker traits.

A trait names one _capability_. Generics let callers plug any type that has that capability in at zero runtime cost;
trait objects let a single value stand in for many types behind a pointer. The senior choice is generics by default,
`dyn` at the seams where heterogeneity or dependency inversion genuinely calls for it.

## Keep traits small and behavior-focused

```rust
// ❌ Kitchen-sink trait — implementors must provide unrelated capabilities
trait Store {
    fn read(&self, key: &str) -> Vec<u8>;
    fn write(&mut self, key: &str, value: &[u8]);
    fn flush(&mut self);
    fn compress(&self, data: &[u8]) -> Vec<u8>;
    fn metrics(&self) -> Stats;
}
```

```rust
// ✅ One capability per trait — implement only what applies, compose at use sites
trait Read {
    fn read(&self, key: &str) -> Option<Vec<u8>>;
}

trait Write {
    fn write(&mut self, key: &str, value: &[u8]);
}
```

WHY: a small trait is easy to implement, easy to mock in tests, and composable (`fn f<S: Read + Write>`). A giant trait
forces every implementor to satisfy capabilities it does not have — a read-only cache should not be made to implement
`write`, `flush`, and `compress`. Bound functions on exactly the capabilities they use.

## Generics vs. `dyn` — the decision

| Want                                              | Choose                               | Mechanism                                                |
| ------------------------------------------------- | ------------------------------------ | -------------------------------------------------------- |
| A reusable algorithm, a hot path                  | Generics `<T: Trait>` / `impl Trait` | Monomorphization → static dispatch, inlinable, zero-cost |
| A heterogeneous collection (`Vec` of mixed types) | `Box<dyn Trait>`                     | One vtable pointer; types erased                         |
| A plugin registry / runtime-selected behavior     | `Box<dyn Trait>` / `&dyn Trait`      | Dynamic dispatch                                         |
| Dependency inversion at an architecture seam      | `dyn` (often `Arc<dyn Trait>`)       | Decouple caller from concrete impl                       |
| To keep binary size and compile time down         | `dyn`                                | One copy of the code, not one per type                   |

```rust
// ✅ Generic: monomorphized, the call to render() inlines, no vtable
fn render_all<T: Render>(items: &[T]) -> Vec<String> {
    items.iter().map(Render::render).collect()
}

// ✅ dyn: genuinely heterogeneous — Dog and Cat in one collection
fn chorus(speakers: &[Box<dyn Speak>]) -> Vec<&'static str> {
    speakers.iter().map(|s| s.speak()).collect()
}
```

WHY the trade-off: generics _monomorphize_ — the compiler stamps out a specialized copy of the function for each `T`,
so dispatch is static, calls inline, and there is no indirection. The cost is code bloat: ten types means ten copies,
which grows the binary and compile time. `dyn` compiles to a single function that dispatches through a vtable pointer:
one copy, smaller binary, but an indirect call the optimizer cannot inline, plus the value lives behind a pointer.
Reach for `dyn` when you _need_ type erasure (a mixed collection, a runtime-chosen strategy) or want to cut
monomorphization bloat — not as a reflexive "the signature looks simpler" default.

## `impl Trait` in argument and return position

```rust
// Argument position: sugar for an anonymous generic. Caller picks the type.
fn print_all(items: impl IntoIterator<Item = String>) {
    for item in items {
        println!("{item}");
    }
}

// Return position (RPIT): "some concrete type implementing Iterator" without naming it.
fn evens(limit: u32) -> impl Iterator<Item = u32> {
    (0..limit).filter(|n| n % 2 == 0)
}
```

WHY: `impl Trait` in argument position is concise for a one-off generic you do not need to name. In return position it
lets you return an unnameable type (a closure, a chained iterator) without `Box`ing it — static dispatch, zero
allocation. Use a named generic `<T: Trait>` instead when the caller must be able to _name_ the type, or when the same
type parameter appears in multiple positions.

### Edition 2024: precise capturing with `use<>`

In edition 2024, a return-position `impl Trait` **implicitly captures every in-scope generic parameter and lifetime**.
That is usually what you want — but when you need to _restrict_ what the returned type borrows, use `+ use<...>` to list
exactly the parameters to capture. This replaces the old `Captures` hack.

```rust
// Capture only 'a and T (not other in-scope generics/lifetimes):
fn parse<'a, T: FromStr>(input: &'a str) -> impl Iterator<Item = T> + use<'a, T> {
    input.split(',').filter_map(|s| s.parse().ok())
}

// Capture nothing — the returned type borrows none of the inputs:
fn make_counter() -> impl FnMut() -> u32 + use<> {
    let mut n = 0;
    move || {
        n += 1;
        n
    }
}
```

WHY: implicit full capture is the right default (it "just works" for the common case), but it can over-constrain a
return type — making it borrow a lifetime it does not actually need and rejecting otherwise-valid callers.
`+ use<'a, T>`
narrows the capture precisely; `+ use<>` captures nothing. If you migrated from an older edition and a return type
suddenly seems to borrow too much, this is the tool.

## The `From`/`Into`/`TryFrom`/`TryInto` family

Implement `From` (infallible) and `TryFrom` (fallible). You get `Into` and `TryInto` automatically via blanket impls,
and both plug into `?`.

```rust
// ✅ Implement From — Into comes free
impl From<u16> for Port {
    fn from(n: u16) -> Self {
        Port(n)
    }
}

// ✅ Implement TryFrom — TryInto comes free; the Error plugs into ?
impl TryFrom<i32> for Port {
    type Error = PortOutOfRange;

    fn try_from(n: i32) -> Result<Self, Self::Error> {
        u16::try_from(n)
            .map(Port)
            .map_err(|_| PortOutOfRange(n))
    }
}

// let p: Port = 8080u16.into();
// let p: Port = 70000i32.try_into()?; // PortOutOfRange converts via ? if From-wired
```

WHY: implement the `From`/`TryFrom` direction and the standard library's blanket `impl<T, U: From<T>> Into<U> for T`
gives you the dual for free — never implement `Into` directly. `TryFrom`'s associated `Error` type integrates with `?`,
so a conversion failure propagates like any other error. This is also how `?` upgrades errors across boundaries (see
error-handling reference).

## Trait objects and dyn-compatibility (object safety)

A trait can be used as `dyn Trait` only if it is **dyn-compatible** (the term that replaced "object-safe"). The rules
that matter in practice:

| A dyn-compatible trait must NOT have… | Because                                       |
| ------------------------------------- | --------------------------------------------- |
| Methods that take `self` by value     | The size is unknown behind a pointer          |
| Generic methods (`fn f<T>(&self)`)    | Cannot build a vtable entry per instantiation |
| Methods returning `Self`              | Caller does not know the concrete size        |
| Associated functions without `&self`  | Nothing to dispatch on                        |

You can keep an otherwise-incompatible method usable by bounding it `where Self: Sized` (it is then unavailable on the
`dyn` form but fine on concrete types).

```rust
trait Animal {
    fn name(&self) -> &str;              // dyn-compatible

    fn clone_box(&self) -> Box<dyn Animal>; // works; returns a trait object, not Self

    fn new() -> Self where Self: Sized;  // excluded from the vtable, still callable on concrete types
}
```

WHY: a `dyn Trait` value is a fat pointer (data pointer + vtable pointer) with no compile-time size; any method whose
signature depends on the concrete size or on a per-type instantiation cannot live in a single shared vtable. Knowing
the rules lets you design a trait that is _both_ usable generically and as a trait object — and lets you diagnose the
"the trait `X` cannot be made into an object" error without flailing.

## RPITIT and the `async fn` in traits caveat

`async fn` in traits (AFIT) and return-position `impl Trait` in traits (RPITIT) are **stable** since 1.75. For
**internal/private** traits, native `async fn` is the idiomatic default — write it directly.

```rust
// ✅ Internal trait — native async fn is fine and idiomatic
trait Cache {
    async fn get(&self, key: &str) -> Option<Vec<u8>>;
}
```

The caveat is for **public, runtime-agnostic** traits: native `async fn` in a trait cannot express a `Send` bound on
the returned future _in the signature_, so a caller cannot require `dyn Cache` futures to be `Send` (needed to spawn
them on a multithreaded runtime), and the trait is not dyn-compatible as written.

| Public async trait need                                  | Use                                                                        |
| -------------------------------------------------------- | -------------------------------------------------------------------------- |
| Must be `dyn`-dispatched, or callers need `Send` futures | `#[trait_variant::make(Send)]`, an explicit boxed future, or `async-trait` |
| Internal/private, single crate                           | Native `async fn` in the trait                                             |

```rust
// ✅ Public, runtime-agnostic trait that must yield Send futures and/or be boxed
use core::future::Future;
use core::pin::Pin;

pub trait Fetch {
    fn fetch<'a>(&'a self, key: &'a str)
        -> Pin<Box<dyn Future<Output = Vec<u8>> + Send + 'a>>;
}
```

WHY: at a long-lived public API boundary the future's `Send`-ness and the trait's dyn-compatibility _are_ part of the
contract — a multithreaded executor needs `Send` futures, and plugin-style consumers need `dyn`. Native `async fn` in
traits cannot state those bounds, so an explicit boxed future, the `trait_variant` macro, or `async-trait` remains the
right tool there. Inside a crate where you control every impl and call site, skip the ceremony and write `async fn`.

## Associated types vs. generic parameters

```rust
// ✅ Associated type — exactly one Item per implementor (the Iterator pattern)
trait Producer {
    type Item;
    fn produce(&self) -> Self::Item;
}

// ✅ Generic parameter — a type may implement the trait for many T
trait Convert<T> {
    fn convert(&self) -> T;
}
```

WHY: an associated type fixes one output type per implementor — `Iterator::Item` is the canonical case, and it keeps
call sites and bounds clean (`I::Item`). A generic trait parameter allows _multiple_ impls for one type (`Convert<i32>`
and `Convert<String>` on the same struct). Choose associated types when the relationship is one-to-one; generic
parameters when one type legitimately implements the trait several ways.

## Sealed traits and marker traits

**Sealed trait**: a public trait you do not want anyone outside your crate to implement (so you can add methods later
without breaking them). Seal it by requiring a private supertrait.

```rust
mod sealed {
    pub trait Sealed {}
}

pub trait Format: sealed::Sealed {
    fn extension(&self) -> &str;
}
// Only types for which you impl `sealed::Sealed` (in your crate) can implement Format.
```

**Marker trait**: a trait with no methods that tags a type with a property (`Send`, `Sync`, `Copy`). Use one to encode
a capability the type system can check without runtime cost.

WHY: sealing lets a trait stay part of your public API while keeping the implementor set closed, so adding a required
method is non-breaking. Marker traits move a property into the type system — `fn spawn<T: Send>` is enforced at compile
time, no runtime check — which is the whole point of Rust's type system applied to traits.
