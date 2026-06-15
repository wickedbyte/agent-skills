# Testing and Verification

The layered evidence model for Rust: unit and doc tests prove examples, integration tests prove the public API, property
tests and fuzzing explore the input space, `trybuild` proves type-level contracts, and Miri/Loom/sanitizers prove the
absence of UB and data races. Each layer catches what the others miss.

## The layers

| Layer                       | Tool                                | What it proves                                               |
| --------------------------- | ----------------------------------- | ------------------------------------------------------------ |
| Examples (white-box)        | `#[cfg(test)] mod tests` unit tests | An internal function behaves on chosen inputs                |
| Runnable docs               | doc-tests (` ``` ` in `///`)        | Every public item has a working example that stays correct   |
| Public contract (black-box) | `tests/` integration tests          | The crate works through its published API                    |
| Input-space search          | `proptest` / `quickcheck`           | Invariants hold across generated inputs, not just examples   |
| Untrusted input             | `cargo-fuzz`                        | Arbitrary bytes cannot crash/panic a parser                  |
| Type-level contract         | `trybuild`                          | Misuse is rejected at compile time with the right diagnostic |
| Concurrency interleavings   | `loom`                              | A lock-free structure is correct under all schedules         |
| Undefined behavior          | `miri`, sanitizers                  | Unsafe/pointer code has no UB or data races                  |

## Unit tests

Co-locate white-box unit tests in a `#[cfg(test)] mod tests` block; they can reach private items. Test the failure
paths,
not just the happy one.

```rust
pub fn parse_port(s: &str) -> Result<u16, ParseError> {
    s.parse().map_err(|_| ParseError::NotANumber)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_valid_port() {
        assert_eq!(parse_port("8080"), Ok(8080));
    }

    #[test]
    fn rejects_non_numeric() {
        assert_eq!(parse_port("nope"), Err(ParseError::NotANumber));
    }
}
```

Name tests after the behavior (`rejects_non_numeric`), not the function (`test_parse_port_2`). `unwrap`/`expect` are
fine
_in tests_ — a panic is a perfectly good test failure.

## Doc-tests — every public item gets a runnable example

A doc-test is both documentation and a test: it compiles and runs as part of the suite, so examples never rot. Give
every public item one.

````rust
/// Returns the first non-zero element.
///
/// ```
/// # use mycrate::first_nonzero;
/// assert_eq!(first_nonzero(&[0, 0, 7]), Some(7));
/// assert_eq!(first_nonzero(&[0, 0, 0]), None);
/// ```
pub fn first_nonzero(xs: &[u32]) -> Option<u32> {
    xs.iter().copied().find(|&x| x != 0)
}
````

Use ` ```compile_fail ` to assert that misuse does **not** compile, and `?`-returning examples for fallible APIs:

````rust
/// ```compile_fail
/// let x = mycrate::Token::new();
/// let _a = x;
/// let _b = x; // use-after-move must not compile
/// ```
````

> **Important:** `cargo nextest` does **not** run doc-tests. Always run `cargo test --doc` alongside it, or the examples
> go unverified.

## Integration tests — black-box the public API

Files under `tests/` are compiled as separate crates that link your library as an external dependency, so they exercise
exactly what consumers see. They cannot touch private items — that is the point.

```rust
// tests/api.rs
use mycrate::{checksum, ChecksumError};

#[test]
fn checksum_of_known_input() {
    assert_eq!(checksum(b"abc"), 294);
}

#[test]
fn empty_input_is_an_error() {
    assert!(matches!(checksum_strict(b""), Err(ChecksumError::Empty)));
}
```

## `cargo-nextest` — the fast default runner

`cargo nextest run` runs each test in its own process with better isolation, parallelism, and output than the built-in
harness, and surfaces flaky/leaky tests. Make it the default for unit and integration tests — then run doc-tests
separately:

```bash
cargo nextest run --workspace --all-features
cargo test --doc                              # nextest does NOT run these
```

## Property testing

Example tests prove a function works on the inputs _you_ thought of; property tests assert an _invariant_ across inputs
the framework generates, and shrink any failure to a minimal case.

```rust
#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn reversing_twice_is_identity(xs: Vec<u8>) {
            let mut ys = xs.clone();
            ys.reverse();
            ys.reverse();
            prop_assert_eq!(ys, xs);
        }

        #[test]
        fn roundtrips(s in ".*") {
            prop_assert_eq!(decode(&encode(&s)), s);
        }
    }
}
```

WHY: round-trip, idempotence, and oracle properties (compare against a slow-but-obvious reference) catch the edge cases
no human enumerates. `proptest` is the usual default; `quickcheck` is the lighter, older alternative.

## Fuzzing — parsers and untrusted input

For anything that ingests bytes from outside (parsers, deserializers, decoders), fuzz it. `cargo-fuzz` drives libFuzzer
to find inputs that crash, panic, or hang.

```rust
// fuzz/fuzz_targets/parse.rs
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = mycrate::parse(data); // must never panic, hang, or UB on any input
});
```

Run with `cargo +nightly fuzz run parse`. A unit test that parses one valid string answers a far weaker question.

## `trybuild` — compile-fail / API-misuse tests

When "this must not compile" is part of your contract (a sealed trait, a misused builder, a type-state API), make it a
test. `trybuild` runs `.rs` fixtures and diffs the compiler output against a recorded `.stderr`.

```rust
#[test]
fn ui() {
    let t = trybuild::TestCases::new();
    t.compile_fail("tests/ui/*.rs"); // each fixture must fail with the expected diagnostic
}
```

WHY: for a rich type API, the misuse paths and their error messages _are_ the product. `trybuild` keeps the diagnostics
from silently regressing during macro/type refactors.

## `loom` — lock-free concurrency

For hand-rolled synchronization (atomics, custom locks, lock-free queues), `loom` exhaustively explores thread
interleavings that are nearly impossible to hit by chance. Write the concurrent test against `loom`'s atomics under
`#[cfg(loom)]` and run it with `RUSTFLAGS="--cfg loom" cargo test`.

## `miri` and sanitizers — undefined behavior

For any `unsafe`, pointer arithmetic, or layout code, prove the absence of UB (see `unsafe-and-ffi.md` for the full
commands):

```bash
cargo +nightly miri test                                   # UB, aliasing, uninit reads
RUSTFLAGS=-Zsanitizer=address cargo +nightly test -Zbuild-std --target x86_64-unknown-linux-gnu
RUSTFLAGS=-Zsanitizer=thread  cargo +nightly test -Zbuild-std --target x86_64-unknown-linux-gnu
```

Miri is a slow semantic interpreter that catches what passes on real hardware; sanitizers instrument native code for
realistic runs. Run Miri on any change to unsafe/pointer/layout code.

## Snapshot testing — `insta`

When the assertion is "this large structured output should not change unexpectedly" (rendered config, serialized AST,
CLI help), `insta` records the value and diffs future runs against it. Review and accept changes with `cargo insta
review`.

```rust
#[test]
fn renders_config() {
    insta::assert_yaml_snapshot!(load_default_config());
}
```

Use snapshots for stable, reviewable output — not for values that legitimately vary (timestamps, addresses), which
produce noisy diffs.

## Assert helpers

| Helper                      | For                                                              |
| --------------------------- | ---------------------------------------------------------------- |
| `assert_eq!` / `assert_ne!` | value equality; prints both sides on failure                     |
| `assert!`                   | a boolean condition                                              |
| `assert_matches!`           | matching against a pattern (incl. enum variants with `_` fields) |

`assert_matches!` was **stabilized in Rust 1.96** and needs an import; it is clearer than an `assert!(matches!(...))`
when you only care that a value fits a shape.

```rust
use std::assert_matches::assert_matches;

assert_matches!(parse_port("nope"), Err(ParseError::NotANumber));
assert_matches!(events.first(), Some(Event::Connected { .. }));
```

## Organizing the suite

- White-box → `#[cfg(test)] mod tests` next to the code.
- Black-box → `tests/` (one file per feature area; share setup via a `tests/common/mod.rs`).
- Benches → `benches/` with Criterion (see `performance.md`).
- Fuzz targets → `fuzz/fuzz_targets/`.
- The public gate for a library is **all** the relevant layers, not just unit tests — run `cargo nextest run` **and**
  `cargo test --doc` at minimum, and add property/fuzz/Miri lanes where the code's risk profile calls for them.
