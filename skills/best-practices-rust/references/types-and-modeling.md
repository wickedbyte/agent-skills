# Types and Modeling

Making illegal states unrepresentable: data-carrying enums, newtypes, `#[non_exhaustive]`, `Default`, builders, value
objects, and immutability by default.

The senior move in Rust is almost always _type design_, not control flow. If a value has meaning, give it a type; if a
set of states is closed, make it an `enum`; if a struct can only exist in valid configurations, enforce that in the
constructor so no `match` arm or downstream check ever has to defend against the impossible.

## Make illegal states unrepresentable

When a struct carries a flag plus the data that flag gates, every reader must remember the correlation — and the
compiler enforces nothing. Collapse the flag and its payload into a data-carrying `enum`.

```rust
// ❌ Flags and payloads that must stay in sync by hand
struct Connection {
    is_connected: bool,
    session_id: Option<String>,   // Some iff is_connected
    disconnect_reason: Option<String>, // Some iff !is_connected
}
// Nothing stops `Connection { is_connected: true, session_id: None, .. }`.
```

```rust
// ✅ The enum makes the invalid combinations unconstructable
enum Connection {
    Connected { session_id: String },
    Disconnected { reason: String },
}

fn describe(conn: &Connection) -> String {
    match conn {
        Connection::Connected { session_id } => format!("up ({session_id})"),
        Connection::Disconnected { reason } => format!("down: {reason}"),
    }
}
```

WHY: the `bool`-plus-`Option` shape has 2 × 2 × 2 = 8 representable combinations, of which only 2 are valid. The `enum`
has exactly 2. The illegal six are now _unspellable_, and the exhaustive `match` means adding a `Reconnecting` state
later is a compile error at every site that needs updating — not a silent fall-through.

## The newtype pattern

A bare `u64` user id can be passed where an order id is expected; the compiler sees two `u64`s and shrugs. Wrap each
meaningful primitive in a one-field tuple struct.

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct UserId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct OrderId(pub u64);

fn cancel_order(_user: UserId, _order: OrderId) { /* ... */ }
// cancel_order(OrderId(1), UserId(2)) is now a type error.
```

| Decision                                    | Guidance                                                                                                         |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Should the inner field be `pub`?            | `pub` for a transparent tag with no invariant; private + constructor when a check must run                       |
| Want the wrapper to vanish at the ABI?      | `#[repr(transparent)]` — guarantees identical layout to the inner type, required for FFI/`transmute` correctness |
| Need the inner type's traits?               | Derive them (`Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord`); they do not pass through automatically        |
| Need full delegation (`Deref`, arithmetic)? | Implement deliberately — do **not** blanket-`Deref` a newtype to its inner type, it leaks the abstraction        |

```rust
// ✅ repr(transparent) when layout must match the inner type (e.g. across FFI)
#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Milliseconds(pub u64);
```

WHY: a newtype is zero-cost — it compiles to the inner representation — yet it buys you a distinct type, a place to hang
methods and trait impls, and a name that documents intent. Derives do not propagate through the wrapper because the
wrapper is a _new_ type; you opt into exactly the semantics that are valid (an `OrderId` should be `Eq` and `Hash`, but
probably not `Add`).

## Value-object structs: private fields + validating constructors

When a struct has an invariant ("an `Email` always contains `@`", "a `Percentage` is 0–100"), make the fields private
and
expose a fallible constructor. Once constructed, the value is trusted everywhere.

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Email(String); // private field — only this module can build one

impl Email {
    pub fn parse(raw: impl Into<String>) -> Result<Self, InvalidEmail> {
        let raw = raw.into();
        if raw.contains('@') {
            Ok(Self(raw))
        } else {
            Err(InvalidEmail(raw))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug)]
pub struct InvalidEmail(String);
```

WHY: validation happens _once_, at the boundary. Functions that take `&Email` never re-check; the type itself is the
proof. This is the "parse, don't validate" discipline — push the check to the edge and carry a type that encodes the
result. Public fields would let any caller construct an invalid `Email` and defeat the whole scheme.

## `#[non_exhaustive]` on extensible public types

Mark public enums and structs you may grow with `#[non_exhaustive]`. Adding a variant or field later then stays a
minor, non-breaking release.

```rust
#[non_exhaustive]
#[derive(Debug)]
pub enum LoadError {
    NotFound,
    PermissionDenied,
    // room to grow without breaking downstream `match`
}
```

| Attribute target            | What it forces on downstream crates                                                        |
| --------------------------- | ------------------------------------------------------------------------------------------ |
| `#[non_exhaustive]` enum    | Every `match` must include a `_ =>` arm                                                    |
| `#[non_exhaustive]` struct  | Cannot use the struct-literal `{ .. }` syntax to build it; cannot exhaustively destructure |
| (within the defining crate) | No restriction — your own crate matches and builds normally                                |

WHY: without it, every public enum variant and struct field is part of your semver contract, so even an additive change
breaks downstream `match` statements and struct literals. `#[non_exhaustive]` trades a small ergonomic cost on consumers
(a mandatory wildcard arm) for the freedom to evolve. Use it on error enums and config structs; skip it on closed
domain types that genuinely will not grow (a `Suit` enum has exactly four variants forever).

## `Default`: derive vs. implement

`#[derive(Default)]` when every field's default is the zero-ish value (`0`, `""`, empty `Vec`, `None`). Implement
`Default` by hand when the sensible default is _not_ the zero value.

```rust
#[derive(Debug, Default)]
struct RetryConfig {
    attempts: u32,   // derive gives 0 — fine if 0 means "no retries"
    backoff: bool,
}

// ✅ Hand-written when the meaningful default is non-zero
struct ServerConfig {
    port: u16,
    workers: usize,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self { port: 8080, workers: 4 }
    }
}
```

WHY: a derived `Default` that produces `port: 0` is a footgun dressed as a convenience. If the only correct default is
non-zero, the derive is actively wrong; write the impl so `ServerConfig::default()` means what a reader expects.

## The builder pattern for many-optional-field construction

When a type has several optional fields, a builder beats a constructor with eight `Option` arguments. Take ownership of
the partial state, return `self` from each setter, and finalize with `build`.

```rust
#[derive(Debug)]
pub struct Request {
    url: String,
    timeout: Option<u64>,
    retries: u32,
}

#[derive(Default)]
pub struct RequestBuilder {
    timeout: Option<u64>,
    retries: u32,
}

impl RequestBuilder {
    pub fn timeout(mut self, ms: u64) -> Self {
        self.timeout = Some(ms);
        self
    }

    pub fn retries(mut self, n: u32) -> Self {
        self.retries = n;
        self
    }

    pub fn build(self, url: impl Into<String>) -> Request {
        Request { url: url.into(), timeout: self.timeout, retries: self.retries }
    }
}

// RequestBuilder::default().timeout(500).retries(3).build("https://example.com")
```

For invariants that must hold _before_ `build` can even be called, reach for the **typestate** variant: encode the
build phase in a type parameter (`RequestBuilder<MissingUrl>` vs `RequestBuilder<HasUrl>`) so that calling `.build()`
before setting the url is a compile error rather than a runtime `unwrap`. Reserve typestate for builders where a missing
required field is a real hazard; the plain builder above is the common default.

WHY: an owned-`self` builder reads as a fluent chain and lets the optional fields default cleanly. The simpler
`..Default::default()` struct-update syntax covers many cases too — reach for a builder when there is real construction
logic, validation, or a desire to hide field layout.

## Immutability by default

Bind with `let`, not `let mut`. Reach for `mut` only when you genuinely mutate in place; prefer _shadowing_ to rebind a
transformed value under the same name.

```rust
// ✅ Shadowing — each binding is immutable; the transformation reads top-to-bottom
let input = "  42 ";
let input = input.trim();
let input: u32 = input.parse().unwrap_or(0);
```

```rust
// ❌ A mut binding kept alive longer than the mutation it was for
let mut name = raw.to_string();
name = name.trim().to_string(); // reassignment, not in-place mutation
```

WHY: `let` is the readable default — a reader sees a name and knows it will not change underneath them. Shadowing lets
you thread a value through type changes (`&str` → `u32`) without inventing `input_trimmed`, `input_parsed`, and without
reaching for `mut`. Save `mut` for the cases where you actually push into a `Vec` or update a counter in a loop;
`clippy` will even flag a `mut` binding that is never mutated.
