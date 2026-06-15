# Tooling and Cargo

The manifest, the lint gate, the formatter, and the daily command loop that keep a crate clean. Encode the standards in
`Cargo.toml` so CI and every contributor enforce them automatically.

## Contents

- `Cargo.toml`: edition, MSRV, and the `[lints]` table
- Clippy lint groups
- rustfmt
- The daily command loop
- Feature-flag discipline
- Semver and public-API stability
- Supply-chain security
- Recommended crates
- Edition-2024 migration
- CI layout

## `Cargo.toml`: edition, MSRV, and `[lints]`

Declare the edition and pin an explicit MSRV. Bump the MSRV deliberately (it is a semver-relevant promise), never by
accident from a new dependency.

```toml
[package]
name = "mycrate"
version = "0.1.0"
edition = "2024"          # stabilized in Rust 1.85 (Feb 2025)
rust-version = "1.96"     # explicit MSRV — the floor you test and promise

[lints.rust]
unsafe_op_in_unsafe_fn = "deny"          # every unsafe op explicitly bracketed (edition 2024)
missing_debug_implementations = "warn"   # public types should derive Debug
missing_docs = "warn"                    # public items should be documented
unreachable_pub = "warn"

[lints.clippy]
all = "warn"                 # the correctness/style/complexity/perf baseline — always on
pedantic = "warn"            # opinionated extras as warnings, NOT deny (see below)
nursery = "warn"
unwrap_used = "warn"         # no unwrap in library paths
expect_used = "warn"
```

The `[lints]` table is the supported, manifest-level way to set lint levels for the whole crate — prefer it over
scattering `#![warn(...)]` in `lib.rs`. Use `unsafe_code = "forbid"` only in a crate meant to contain zero `unsafe`.

## Clippy lint groups

| Group              | Setting                                       | Why                                                              |
| ------------------ | --------------------------------------------- | ---------------------------------------------------------------- |
| `clippy::all`      | always `warn` (gate to deny in CI)            | correctness, suspicious, complexity, style, perf — the baseline  |
| `clippy::pedantic` | `warn`, `#[allow]` the noisy individual lints | great signal, but some lints are stylistic; never wholesale-deny |
| `clippy::nursery`  | `warn`                                        | newer/experimental lints; treat as advisory                      |
| `clippy::perf`     | included in `all`; low-noise wins             | flags needless clones, allocations, inefficient patterns         |
| `clippy::cargo`    | `warn`                                        | manifest hygiene (deps, metadata); low noise                     |

WHY warn-not-deny for `pedantic`/`nursery`: these groups intentionally include opinionated and occasionally
false-positive lints. Setting the _group_ to deny makes a routine `clippy` upgrade fail your build over style. Keep them
at warn and silence the few that do not fit with a targeted, commented `#[allow(clippy::specific_lint)]` — never disable
the whole group.

## rustfmt

Use the defaults. A formatter's value is that everyone's diffs look the same; per-project style overrides erode that.

```toml
# rustfmt.toml — only if you truly need it
imports_granularity = "Crate"
group_imports = "StdExternalCrate"
```

> Both `imports_granularity` and `group_imports` are **nightly-gated** — they run under `cargo +nightly fmt` and are
> ignored by stable `cargo fmt`. If your team is on stable only, leave `rustfmt.toml` empty and take the defaults.

## The daily command loop

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo nextest run --workspace --all-features
cargo test --doc                                   # nextest does NOT run doc-tests
```

`-D warnings` turns the warn-level lints into hard errors _at the gate_ without baking deny into the manifest, so a
local
`cargo build` stays friendly while CI stays strict. `--all-targets` covers tests, benches, and examples;
`--all-features`
catches feature-gated code that would otherwise rot.

## Feature-flag discipline

Cargo features are **additive**: enabling a feature may only add behavior, never remove or change it, because Cargo
unifies the union of features across the dependency graph.

```toml
[features]
default = ["std"]          # std on by default; downstream opts into no_std with default-features = false
std = []
serde = ["dep:serde"]      # an optional dep, gated and named

[dependencies]
serde = { version = "1", optional = true }
tokio = { version = "1", optional = true }   # runtime deps stay optional — see async.md
```

- Make `std` an opt-_out_ feature in `default`, so `no_std` users disable it; never invert the polarity.
- **No mutually-exclusive features.** If two features cannot coexist, the graph will eventually enable both and break.
  Model the choice as a runtime parameter or separate crates instead.
- Keep runtime-specific deps (`tokio`, etc.) behind optional features so the core stays runtime-agnostic.

## Semver and public-API stability

The public API is a contract. Before release, check it did not break:

```bash
cargo semver-checks       # detects semver-incompatible API changes against the published version
cargo public-api diff     # human-readable diff of the exported surface
```

Shrink the public surface to what you mean to support; mark extensible public enums/structs `#[non_exhaustive]` so
adding a variant/field later is not a breaking change. A stable crate must not expose an unstable public dependency.

## Supply-chain security

Three complementary layers — use all three on anything that ships:

| Tool          | Covers                                                                             |
| ------------- | ---------------------------------------------------------------------------------- |
| `cargo audit` | known RustSec vulnerabilities in `Cargo.lock`                                      |
| `cargo deny`  | policy: advisories, license allow/deny, banned crates, source restrictions         |
| `cargo vet`   | auditable trust/provenance for third-party deps (`supply-chain/` checked into VCS) |

```bash
cargo audit
cargo deny check
```

## Recommended crates

| Need                       | Crate                         | Note                                                                      |
| -------------------------- | ----------------------------- | ------------------------------------------------------------------------- |
| Library error type         | `thiserror`                   | derives `Error`, `From`, `Display` on a typed enum                        |
| Application error handling | `anyhow`                      | ergonomic `Result` + `.context(...)`; not for library APIs                |
| Serialization              | `serde` (+ `serde_json`, …)   | gate behind an optional `serde` feature in libraries                      |
| Async runtime              | `tokio`                       | keep it **optional** and at the binary edge, not in a general-purpose lib |
| Benchmarking               | `criterion`                   | dev-dependency; see `performance.md`                                      |
| Property tests             | `proptest`                    | dev-dependency                                                            |
| Fast async-aware locks     | `parking_lot` / `tokio::sync` | per the sync vs async context                                             |

The rule: runtime- and framework-specific deps stay behind optional features so consumers opt in. Justify every new
dependency — each one is supply-chain surface and a semver liability.

## Edition-2024 migration

1. Set `edition = "2024"` and an explicit `rust-version` in `Cargo.toml`.
2. Run `cargo fix --edition --all-features` — re-run across targets/feature combos; one pass rarely catches everything.
3. Wrap extern blocks as `unsafe extern { ... }`; rewrite `#[no_mangle]` → `#[unsafe(no_mangle)]` (and `export_name` /
   `link_section` likewise inside `unsafe(...)`).
4. Audit return-position `impl Trait`: edition 2024 captures **all** in-scope generics/lifetimes. Restrict with
   `+ use<'a, T>` (this replaces the old `Captures` trick) or `+ use<>` to capture nothing.
5. Note the never-type fallback is now `!` (was `()`); the `never_type_fallback_flowing_into_unsafe` lint is deny-level,
   so recheck inference in heavily generic / unsafe code.
6. `std::env::set_var` / `remove_var` are now `unsafe` — wrap them with a SAFETY note about no concurrent access.
7. `cargo fix` is a migration assistant, not a proof of equivalence; run the full test + semver suite afterward.

> **Do not emit `gen` blocks or `gen fn` generators.** They are still unstable on Rust 1.96 (nightly-only behind
> `#![feature(gen_blocks)]`) and will not build on stable. Hand-write an `Iterator`/`Stream` impl or use a helper crate.

Also watch two subtle behavior changes when migrating: `IntoIterator for Box<[T]>` now yields `T` _by value_, and
`Range`/`RangeInclusive` became `Copy` in 1.96 (a range no longer moves when used).

## CI layout

Run the gates as parallel jobs so feedback time is the slowest lane, not the sum. Keep the stronger nightly-only
diagnostics (Miri, sanitizers) in their own lanes.

```yaml
name: ci
on: [push, pull_request]

jobs:
    stable:
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@v4
            - run: rustup toolchain install stable --component rustfmt --component clippy
            - run: cargo fmt --all -- --check
            - run: cargo clippy --workspace --all-targets --all-features -- -D warnings
            - run: cargo nextest run --workspace --all-features
            - run: cargo test --doc
            - run: cargo install --locked cargo-audit cargo-deny && cargo audit && cargo deny check

    miri:
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@v4
            - run: rustup toolchain install nightly --component miri && cargo +nightly miri setup
            - run: cargo +nightly miri test # only needed if the crate has unsafe / pointer code

    semver:
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@v4
            - run: cargo install cargo-semver-checks --locked
            - run: cargo semver-checks
```
