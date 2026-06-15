# Performance

How to make Rust fast without guessing. Architecture and data layout dominate; codegen knobs are a last resort. The one
rule that outranks all others: **measure first, on release builds, and keep only the change that survives
re-measurement.**

## The order of operations

1. **Algorithm** — the right `O(...)` beats every micro-tweak. A `HashMap` lookup where you had a linear scan is the
   win.
2. **Data layout & allocation** — contiguity, cache locality, preallocation, fewer clones.
3. **Abstraction shape** — iterators that fuse, static vs dynamic dispatch, borrow vs own.
4. **Codegen knobs** — `#[inline]`, atomics ordering, the release profile. Evidence-gated, last.

Spending time at level 4 before level 1 is how cargo-culted Rust gets written. Optimize architecture before codegen.

## Measure first — Criterion + `black_box`

Never conclude from a debug build or a single run. Benchmark release-like builds with a statistically guided harness,
and wrap inputs/outputs in `std::hint::black_box` so the optimizer cannot delete the work or hoist setup into the timer.

```rust
// benches/sum.rs
use criterion::{criterion_group, criterion_main, Criterion};
use std::hint::black_box;

fn sum(xs: &[u64]) -> u64 {
    xs.iter().copied().sum()
}

fn bench_sum(c: &mut Criterion) {
    let data: Vec<u64> = (0..10_000).collect();
    c.bench_function("sum_10k", |b| b.iter(|| sum(black_box(&data))));
}

criterion_group!(benches, bench_sum);
criterion_main!(benches);
```

```rust
// ❌ not a benchmark — one run, no black_box, the optimizer may delete it all
fn main() {
    let data: Vec<u64> = (0..10_000).collect();
    let _ = sum(&data); // times setup + alloc, gives the optimizer free rein
}
```

A good protocol: record `rustc -Vv`, target triple, profile, and `RUSTFLAGS`; benchmark release builds only; use fixed
plus scaled input sizes; then profile the winners with `perf`/`samply` and a flamegraph on a realistic workload. Collect
p50/p95/p99, not just the mean. `cargo bench` runs the bench profile (which inherits from release); `criterion` adds
warmup, outlier detection, and regression tracking; `iai-callgrind` gives stable instruction counts. **If a change does
not survive re-measurement, revert it — clarity wins ties.**

## Data layout follows the access pattern

`size_of::<T>()` includes padding; field order affects it. Lay out hot data the way it is read.

- **SoA vs AoS.** If a loop streams one field across many elements, struct-of-arrays (`x: Vec<f32>, y: Vec<f32>`) keeps
  that field contiguous and cache-friendly. If you touch a whole element at a time, array-of-structs is fine.
- **Field ordering.** Group fields to minimize padding; `rustc` may reorder unless you pin layout with `#[repr]`.
- **`#[repr]`** only when layout is a contract (FFI, transmute, SIMD) — see `unsafe-and-ffi.md`. Do not reach for it for
  speed without a measurement.

```rust
// ✅ SoA when the hot loop streams one field — sum_x touches only contiguous f32
struct Positions {
    x: Vec<f32>,
    y: Vec<f32>,
    z: Vec<f32>,
}

impl Positions {
    fn with_capacity(n: usize) -> Self {
        Self { x: Vec::with_capacity(n), y: Vec::with_capacity(n), z: Vec::with_capacity(n) }
    }
    fn sum_x(&self) -> f32 {
        self.x.iter().copied().sum()
    }
}
```

WHY: AoS forces every cache line to carry `y` and `z` you never read; SoA packs only the field the loop wants. Layout
is a performance choice — make it deliberately, driven by the access pattern, not by conceptual elegance.

## Preallocate and reuse buffers

Growing a `Vec` in a loop reallocates and copies repeatedly. When the cardinality is known or boundable, size it once.

```rust
// ❌ reallocates as it grows
let mut out = Vec::new();
for x in &input {
    out.push(transform(x));
}

// ✅ one allocation
let mut out = Vec::with_capacity(input.len());
for x in &input {
    out.push(transform(x));
}
```

For repeated passes, reuse a scratch buffer with `clear()` (which keeps the capacity) instead of allocating a fresh
`Vec` each iteration:

```rust
let mut scratch = Vec::with_capacity(1024);
for chunk in chunks {
    scratch.clear(); // retains capacity — no realloc next pass
    scratch.extend(chunk.iter().map(decode));
    process(&scratch);
}
```

## Avoid needless allocation and clone

A `.clone()` sprinkled to quiet the borrow checker is a design smell, not a fix — borrow instead, or move once.

- Take `&str` / `&[T]` / `&Path` parameters so callers need not allocate to call you (see `ownership-and-borrowing.md`).
- Slice instead of copying substrings: `&s[a..b]` over `s[a..b].to_string()`.
- Use `Cow<'_, str>` when a function _usually_ borrows but _occasionally_ needs to own (e.g. escaping that rarely
  fires).

```rust
use std::borrow::Cow;

// ✅ allocates only when a replacement actually happens
fn normalize(input: &str) -> Cow<'_, str> {
    if input.contains('\t') {
        Cow::Owned(input.replace('\t', " "))
    } else {
        Cow::Borrowed(input)
    }
}
```

## Iterators fuse — don't `collect` mid-pipeline

Iterator adapters compile to roughly the same code as a hand-written loop; they are a real zero-cost abstraction. The
trap is materializing an intermediate `Vec` in the middle of a chain, which adds an allocation and a second walk.

```rust
// ❌ collects into a throwaway Vec, then walks it again
fn sum_even(xs: &[u64]) -> u64 {
    let evens: Vec<u64> = xs.iter().copied().filter(|x| x % 2 == 0).collect();
    evens.iter().sum()
}

// ✅ stays lazy — one fused pass, zero heap allocation
fn sum_even(xs: &[u64]) -> u64 {
    xs.iter().copied().filter(|x| x % 2 == 0).sum()
}
```

Iterating with adapters (`.iter()`, `.map()`, …) also elides bounds checks that manual `xs[i]` indexing in a `0..len`
loop forces the compiler to keep. Prefer the iterator form; it is both faster and clearer. `collect` only when you
genuinely need stored data.

## `#[inline]` / `#[cold]` — sparingly, with evidence

`rustc` already auto-inlines across a crate when worthwhile; `#[inline]` is a _hint_, and a bad one can bloat code and
hurt i-cache behavior.

| Attribute           | Use when                                                | Avoid                                  |
| ------------------- | ------------------------------------------------------- | -------------------------------------- |
| `#[inline]`         | a small cross-crate function a benchmark shows benefits | sprinkling it "for speed"              |
| `#[inline(always)]` | a tiny leaf function, proven by measurement             | almost everywhere — it is rarely right |
| `#[cold]`           | a rarely-taken path (error formatting, slow fallback)   | hot paths                              |

```rust
#[cold]
fn report_corruption() -> Error {
    Error::Corrupt
}
```

WHY: trust the optimizer by default. `#[inline(always)]` overrides the compiler's cost model and frequently makes things
slower or larger. Reach for these only after a flamegraph points at the call.

## Atomics, contention, and false sharing

Prefer ownership transfer and thread-local reduction over shared mutable state. When you do share, pick the **weakest
correct** `Ordering` — `Relaxed` for a non-coordinating counter, not `SeqCst` by reflex.

```rust
use std::sync::atomic::{AtomicU64, Ordering};

static HITS: AtomicU64 = AtomicU64::new(0);

// ✅ a stats counter coordinates nothing — Relaxed is correct and cheapest
fn record_hit() {
    HITS.fetch_add(1, Ordering::Relaxed);
}
```

```rust
// ❌ SeqCst by habit — a full barrier for a counter that orders nothing
HITS.fetch_add(1, Ordering::SeqCst);
```

- Reduce into a thread-local accumulator and combine once at the end rather than hammering one shared atomic/lock per
  iteration. A `Mutex<u64>` incremented in a tight loop serializes every thread.
- `parking_lot::Mutex`/`RwLock` are smaller and often faster than `std` under contention; consider them for hot locks.
- **False sharing**: two atomics on the same cache line ping-pong between cores. Pad/align hot per-thread counters
  (e.g. `#[repr(align(64))]`) to separate lines.

Choose orderings by a correctness argument and document it; never by habit. (TSan cannot validate fence-based or
inline-asm synchronization — see `testing-and-verification.md`.)

## The release profile

Cargo's release defaults are conservative (`opt-level = 3`, `lto = false`, `codegen-units = 16`). For a CPU-bound binary
you ship, this baseline trades build time for runtime:

```toml
[profile.release]
lto = "thin"          # cross-crate inlining; "fat" is slower to build for a marginal gain
codegen-units = 1     # better optimization at the cost of parallel build time
strip = "debuginfo"   # smaller binary; keep symbols if you need postmortems
# panic = "abort"     # drops unwinding tables (smaller, slightly faster) — but no catch_unwind,
                      # and it changes test/FFI behavior. Opt in deliberately, not by default.
```

| Knob                  | Default    | Flip it when                                 | Cost                                     |
| --------------------- | ---------- | -------------------------------------------- | ---------------------------------------- |
| `lto = "thin"`        | `false`    | shipping a CPU-bound binary/lib              | slower link                              |
| `codegen-units = 1`   | `16`       | runtime matters more than build time         | longer builds                            |
| `strip = "debuginfo"` | `"none"`   | shipping smaller artifacts                   | worse stack traces                       |
| `panic = "abort"`     | `"unwind"` | you never catch panics and want the size win | breaks `catch_unwind`; affects FFI/tests |
| `target-cpu`          | generic    | a known internal deployment CPU              | loses portability                        |

WHY `panic = "abort"` is a trade-off: it removes unwinding machinery (smaller, marginally faster) but means a panic
aborts the process — no `catch_unwind` recovery — and it interacts with FFI boundaries and the test harness. Only set it
when you are sure no code relies on unwinding.

## What not to micro-optimize

The big wins in real code are: the wrong algorithm, the wrong data structure, I/O in a loop instead of batched, and
per-element allocation on a hot path. Below that, every tweak is a few percent and easily regresses. Profile, fix the
true bottleneck, re-measure, and keep the change only if the improvement is material — otherwise revert for clarity.
