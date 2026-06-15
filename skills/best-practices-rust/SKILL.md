---
name: best-practices-rust
description: >-
    Use when writing, modifying, or reviewing Rust code (.rs files, Cargo.toml) — including structs, enums, traits,
    generics, error handling, async, lifetimes, or any Rust-emitting task. Applies to every Rust task and targets Rust
    1.96 with edition 2024. Triggers for making illegal states unrepresentable (enums + newtypes), borrowing over
    ownership (`&str`/`&[T]`/`&Path`, not `&String`/`&Vec`), `Result`/`Option` + `?` over `unwrap`, `thiserror` for libs
    and `anyhow` for apps, deriving standard traits, `From`/`TryFrom`, small traits + generics over `dyn`, iterator
    pipelines, exhaustive `match`, `#[non_exhaustive]`, clippy-clean code, scoped `unsafe` with `// SAFETY:`, and
    edition-2024 features (async fn in traits, `let-else`, `use<>` precise capturing, `unsafe extern`). Note: `gen`
    blocks are still unstable on 1.96 — do not emit them. Use this even when the user does not say "idiomatic Rust".
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# How to Write Rust

This skill captures an opinionated, framework-agnostic Rust style targeting the language as it stands in mid-2026 (Rust
1.96, edition 2024, clippy as a gate, `cargo nextest`, `thiserror` + `anyhow`). Follow it for any Rust work.

> **Toolchain and crate versions move faster than this document.** This skill deliberately does **not** pin crate
> version numbers; the `version = "1"` lines in examples are illustrative semver, not recommendations to freeze.
> Use whatever the project's `Cargo.toml` and toolchain already declare; when adding a dependency or bumping the
> toolchain, **verify the current stable release yourself** (check crates.io / release notes) rather than trusting a
> number here. (Rust 1.96 / edition 2024 is the deliberate language target, not a tool version — though even the MSRV
> you declare should reflect the project's real floor.)

## The One Idea

**Rust is a language for making invariants explicit at compile time.** Instead of _documenting_ what must be true and
_hoping_ callers comply, you encode it in the type system so the compiler rejects the illegal program before it runs.
Ownership and borrowing make data flow and mutation visible in every signature; `enum`, `Option`, `Result`, and newtypes
make illegal states unrepresentable; an exhaustive `match` turns "I forgot a case" from a production incident into a
compile error. The senior move is almost never the cleverest code — it is the code that makes ownership, failure modes,
and cost obvious to the next reader, and that lets the borrow checker, the type checker, and a human reviewer all agree
at once.

Two consequences shape everything below:

1. **When you are fighting the borrow checker, the design is usually wrong — not the checker.** A `.clone()` sprinkled
   to
   make an error go away, or an `Rc<RefCell<T>>` reached for reflexively, is a signal to rethink ownership, not a fix.
2. **Make the cost visible.** Allocation, copying, dynamic dispatch, and locking should be apparent in the types and
   signatures, so a reader can see what a function does to memory without running it.

## Framework and Ecosystem Conventions Take Precedence

This skill is **framework-agnostic**; an established framework's or major crate's own conventions win wherever they
conflict. An `axum` or `actix-web` handler has the signature and extractor patterns that framework expects; a `bevy`
system follows ECS conventions, not hand-rolled ownership trees; a `serde` type derives `Serialize`/`Deserialize` the
serde way; a `tokio` app commits to that runtime. A `#![no_std]` embedded crate cannot follow `std`-assuming advice
here at all. Follow the framework, the runtime, and the project's established patterns first; apply this skill's
guidance to everything they leave open — your domain types, error enums, trait design, and the clippy/test discipline.
Do not refactor working framework-idiomatic code toward these defaults just because they differ.

## When to Use This Skill

Use it for any of:

- Authoring or editing `.rs` files — structs, enums, traits, functions, modules
- Designing domain types, error enums, trait abstractions, public crate APIs
- Writing async code, CLIs, services, libraries, parsers, systems code
- Setting up or changing `Cargo.toml`, the `[lints]` table, `rustfmt.toml`, clippy config, CI
- Reviewing Rust for `unwrap` in library code, `&Vec`/`&String` params, stringly-typed code, gratuitous `clone`, or
  `Rc<RefCell>` papering over a borrow-checker fight
- Migrating a crate to edition 2024

Do not use it for: generated bindings you do not own, or `build.rs` glue where the constraints differ.

## Core Defaults — apply unless the task gives a specific reason not to

### 1. Make illegal states unrepresentable

Reach for an `enum` (often data-carrying) for any closed set of states, and a newtype for any primitive that has
meaning. A `PostStatus` enum with an exhaustive `match` beats a `&str` compared against `"draft"`; `struct UserId(u64)`
beats a bare `u64` that could be swapped with an `OrderId`.

### 2. Borrow by default; take ownership only to store, move, or consume

Parameters should be `&str`, `&[T]`, `&mut [T]`, `&Path` — never `&String`, `&Vec<T>`, or `&PathBuf`. Return owned
`String` / `Vec<T>` when you produce new data. This leaves the copy decision with the caller.

```rust
fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}
```

### 3. Use `impl Into<_>` / `impl AsRef<_>` for ergonomic inputs

`fn new(name: impl Into<String>)` lets callers pass `&str` or `String`; `fn open(p: impl AsRef<Path>)` is the std idiom.
See `references/ownership-and-borrowing.md` for `Cow`, clone discipline, and lifetime elision.

### 4. Model failure with `Result<T, E>` and absence with `Option<T>`; propagate with `?`

There are no exceptions — errors are values. Forbid `unwrap` / `expect` in library code paths (tests, examples, and
provably-impossible internal cases excepted). In a binary, a deliberate `expect("config must load")` with a useful
message is fine.

### 5. `thiserror` for libraries, `anyhow` for applications

A library exposes a typed error enum (deriving `thiserror::Error`, with `#[from]` and `#[source]`) so callers can match;
an application uses `anyhow::Result` + `.context(...)` for ergonomic propagation. Never ship `Result<T, String>` in an
API that outlives a prototype.

```rust
#[derive(thiserror::Error, Debug)]
pub enum PostError {
    #[error("no post found for id {0}")]
    NotFound(String),
    #[error("unable to read post at {path}")]
    UnableToRead {
        path: String,
        #[source]
        source: std::io::Error,
    },
}
```

### 6. Pattern-match over boolean gymnastics

`match` when exhaustiveness matters, `if let` for a single happy path, and `let ... else { return ... }` for early exit.
Never `if x.is_some() { x.unwrap() }`.

```rust
let Some(config) = load_config() else {
    return Err(PostError::NotFound("config".into()));
};
```

### 7. Derive the standard traits liberally

Default to `#[derive(Debug, Clone, PartialEq)]` on data types, adding `Eq, Hash, PartialOrd, Ord, Copy, Default` where
semantically valid, and `Serialize`/`Deserialize` at serialization boundaries. `Debug` on every public type is a
near-universal expectation (`missing_debug_implementations` warns).

### 8. Implement `From` / `TryFrom` for conversions, not ad-hoc constructors

`From` for infallible conversions (you get `Into` free); `TryFrom` for fallible ones (you get `try_into` free). This
plugs your types into the standard conversion ecosystem and the `?` operator.

### 9. Keep traits small and behavior-focused; prefer generics, use `dyn` at seams

One capability per trait, not a kitchen sink. Use generics (`fn f<T: Trait>` / `impl Trait`) for reusable algorithms and
hot paths — they monomorphize to zero-cost code. Reserve `Box<dyn Trait>` for genuine heterogeneity, plugin registries,
and dependency-inversion boundaries. See `references/traits-and-generics.md`.

### 10. Prefer iterator pipelines for map/filter/fold, loops for clear mutation

Iterators fuse to loop-equivalent codegen — but avoid materializing an intermediate `Vec` mid-pipeline; keep it lazy and
`collect` only when you need storage. A plain `for` loop is idiomatic; do not contort one into a chain just to look
functional.

### 11. Let lifetime elision do the work

Name a lifetime only when a returned borrow ties to a specific input. Annotating `'a` everywhere is noise, not rigor.

### 12. Keep the public surface smaller than the directory tree

Modules are private by default; helpers are `pub(crate)` or private; re-export the intended API from the crate root.
Prefer methods and constructors over public fields, so invariants cannot be violated and the layout can change later.

### 13. Mark extensible public enums and structs `#[non_exhaustive]`

This lets you add variants or fields later without a breaking change, and forces downstream `match` arms to include a
`_ =>` wildcard.

### 14. Be clippy-clean and rustfmt-clean

Treat `cargo clippy -- -D warnings` as a gate. Enable `clippy::pedantic` / `clippy::nursery` as warnings and `#[allow]`
the noisy individual lints rather than disabling the group. Enable `unsafe_op_in_unsafe_fn`. See
`references/tooling-and-cargo.md`.

### 15. Treat `unsafe` as a last-mile tool, not a design strategy

Start in safe Rust; introduce `unsafe` only with a concrete reason; keep the block tiny; write a `// SAFETY:` comment
stating the invariant; expose a _safe_ wrapper rather than an `unsafe fn` wherever possible. See
`references/unsafe-and-ffi.md`.

### 16. Provide `Default` and a builder where construction is non-trivial; use `const`/`static` deliberately

`#[derive(Default)]` for sensible zero-values; a builder (or `..Default::default()`) for types with many optional
fields. Prefer `const` for compile-time constants; use `static` only for genuinely global state, with the weakest
correct atomic ordering (`Relaxed` for a stats counter, not `SeqCst` by habit).

## Quick Triage Table

| Situation                                    | Default choice                                           |
| -------------------------------------------- | -------------------------------------------------------- |
| Modeling a closed set of states              | Data-carrying `enum` + exhaustive `match`                |
| Modeling a meaningful primitive              | Newtype `struct UserId(u64)`                             |
| A string parameter                           | `&str` (not `&String` / `String` unless stored)          |
| A slice parameter                            | `&[T]` / `&mut [T]` (not `&Vec<T>`)                      |
| A path parameter                             | `impl AsRef<Path>` or `&Path` (not `&PathBuf`)           |
| An ergonomic owned input                     | `impl Into<String>`                                      |
| Signaling a recoverable error (library)      | `Result<T, E>` with a `thiserror` enum                   |
| Signaling a recoverable error (application)  | `anyhow::Result<T>` + `.context(...)`                    |
| Absence                                      | `Option<T>`                                              |
| Propagating an error                         | `?` (never `unwrap` in lib code)                         |
| Early return on a `None` / `Err`             | `let ... else { return ... }`                            |
| A fallible conversion                        | `impl TryFrom` (gives `try_into`)                        |
| An infallible conversion                     | `impl From` (gives `Into`)                               |
| Reusable algorithm / hot path                | Generics (`impl Trait` / `<T: Trait>`), static dispatch  |
| Heterogeneous collection / plugin seam       | `Box<dyn Trait>`                                         |
| A public enum/struct that may grow           | `#[non_exhaustive]`                                      |
| Async fn in a public, runtime-agnostic trait | Explicit future bounds / `trait_variant` (see async ref) |

## Reference Files

Read the relevant file when the SKILL.md guidance leaves a judgment call open:

- `references/types-and-modeling.md` — Enums, newtypes, making illegal states unrepresentable, `#[non_exhaustive]`,
  `Default`, the builder pattern, value-object structs, immutability by default.
- `references/ownership-and-borrowing.md` — The borrow-vs-own decision, `&str` / `&[T]` / `AsRef` / `Cow`, clone
  discipline, lifetimes and elision, escaping the `Rc<RefCell>` trap.
- `references/error-handling.md` — `Result` / `Option` / `?`, `thiserror` vs `anyhow`, error enums, `From` /
  `#[source]`,
  panic vs recoverable, the `unwrap` policy.
- `references/traits-and-generics.md` — Small traits, generics vs `dyn`, monomorphization cost, blanket impls, `From` /
  `Into` / `TryFrom`, RPITIT, dyn-compatibility (object safety).
- `references/iterators-and-control-flow.md` — Iterator pipelines vs loops, avoiding intermediate allocation, pattern
  matching, `let-else`, `if let` chains (1.95+), exhaustiveness.
- `references/async.md` — When to go async, runtime-agnostic library APIs, `async fn` in traits (AFIT) and its
  public-API
  caveats, async closures, not holding a guard across `.await`, tokio at the edges.
- `references/performance.md` — Measure-first discipline, data layout (SoA vs AoS), preallocation, `#[inline]` /
  `#[cold]`
  sparingly, atomics and contention, Criterion + `black_box`, release profile (`lto`, `codegen-units`).
- `references/unsafe-and-ffi.md` — Scoped `unsafe` + `// SAFETY:`, `unsafe_op_in_unsafe_fn`, safe wrappers, `#[repr(C)]`
  / `#[repr(transparent)]`, edition-2024 `unsafe extern`, no unwinding across FFI, Miri.
- `references/testing-and-verification.md` — Unit / doc / integration tests, `cargo-nextest`, property tests (
  `proptest`),
  fuzzing (`cargo-fuzz`), `trybuild` compile-fail, Loom, Miri, sanitizers.
- `references/tooling-and-cargo.md` — `Cargo.toml` edition / MSRV, the `[lints]` table, clippy groups, rustfmt,
  feature-flag discipline (additive, `std` opt-in), semver, `cargo audit` / `deny` / `vet`, CI layout, recommended
  crates, and the edition-2024 migration.

## Common Mistakes (and the fix)

| Mistake                                                               | Fix                                                                        |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `.unwrap()` / `.expect()` scattered through library code              | Return `Result` / `Option`, propagate with `?`; reserve `unwrap` for tests |
| `fn f(v: &Vec<T>)` / `&String` / `&PathBuf`                           | `fn f(v: &[T])` / `&str` / `&Path`                                         |
| `.clone()` sprinkled to satisfy the borrow checker                    | Redesign ownership — borrow, split borrows, or move once                   |
| Stringly-typed domain (`status: &str`, `== "draft"`)                  | Data-carrying `enum` + exhaustive `match`; newtype meaningful primitives   |
| `Rc<RefCell<T>>` everywhere to dodge the borrow checker               | Ownership trees, indices/handles into a `Vec`/arena, or `&mut` threading   |
| `if x.is_some() { x.unwrap() }` / nested `if` chains                  | `match`, `if let`, or `let ... else { return }`                            |
| `Result<T, String>` as a library error type                           | A typed `enum` deriving `thiserror::Error` (lib) or `anyhow` (app)         |
| `collect::<Vec<_>>()` mid-pipeline, then iterate again                | Keep the iterator lazy; `collect` only when you need storage               |
| `Box<dyn Trait>` in a hot loop / by default                           | Generics (`impl Trait` / `<T: Trait>`) for static dispatch                 |
| Public `async fn` in a runtime-agnostic trait; tokio baked into a lib | Keep the core runtime-agnostic; let the binary pick the runtime            |
| `#[inline(always)]` sprinkled "for speed"; benchmarking debug builds  | Trust the optimizer; measure release builds with Criterion + `black_box`   |
| Emitting `gen { ... }` blocks                                         | Still unstable on 1.96 — hand-write an `Iterator`/`Stream` impl instead    |
| Everything `pub`, public fields exposing invariants                   | Private by default; methods enforce invariants; `#[non_exhaustive]`        |

## Migrating a Crate to Edition 2024

1. Set `edition = "2024"` and an explicit `rust-version` (MSRV) in `Cargo.toml`.
2. Run `cargo fix --edition --all-features` (may need several passes across targets and feature combinations).
3. Wrap extern blocks as `unsafe extern { ... }` and rewrite `#[no_mangle]` as `#[unsafe(no_mangle)]`.
4. Audit return-position `impl Trait`: edition 2024 captures all in-scope generics/lifetimes — add `+ use<...>` to
   restrict capture where the old behavior is wanted.
5. Note the never-type fallback is now `!` (was `()`); recheck inference in heavily generic code.
6. Add a `[lints]` table and drive `cargo clippy -- -D warnings` to clean.

## Pre-Commit Self-Check

Before saying "done" on a Rust change, verify:

- [ ] `cargo fmt --all -- --check` is clean and `cargo clippy --all-targets --all-features -- -D warnings` passes.
- [ ] `cargo nextest run` (or `cargo test`) **and** `cargo test --doc` are green, covering success _and_ failure paths.
- [ ] No `unwrap` / `expect` / `panic!` / `todo!` / `dbg!` in non-test library code paths.
- [ ] Parameters borrow (`&str` / `&[T]` / `&Path`) unless ownership is genuinely required; no `&Vec` / `&String`.
- [ ] Errors are typed (`thiserror` enum or `anyhow` with context), not `String`; `Option` for absence; `?` to
      propagate.
- [ ] Domain concepts are enums / newtypes, not stringly- or primitively-typed; every `match` on an owned enum is
      exhaustive (no lazy catch-all hiding a missed variant).
- [ ] Public types derive `Debug` (and `Clone` / `PartialEq` where sensible); the public surface is minimal, with
      `#[non_exhaustive]` on extensible types and a doctest on public items.
- [ ] Every `unsafe` block is minimal and carries a `// SAFETY:` comment; a safe wrapper is exposed;
      `unsafe_op_in_unsafe_fn` is satisfied. Run `cargo +nightly miri test` if pointer/layout code changed.
- [ ] No needless `.clone()`, no intermediate `collect()` mid-pipeline, no `Rc<RefCell>` papering over a borrow fight;
      capacity is hinted (`with_capacity`) where cardinality is known.
- [ ] `Cargo.toml` declares `edition = "2024"` and an MSRV; no `gen` blocks (unstable on 1.96); new deps are justified.
