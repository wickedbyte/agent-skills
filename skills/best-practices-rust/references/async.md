# Async

Async is a concurrency model for I/O-bound work, not a maturity badge. Reach for it when you have many concurrent
waits; keep CPU-bound and core logic synchronous, and push the runtime to the binary edge.

## When to go async — and when not to

| Situation                                                   | Choice                                                                    |
| ----------------------------------------------------------- | ------------------------------------------------------------------------- |
| Thousands of concurrent network sockets / RPCs / DB queries | Async (`tokio`, `smol`, …)                                                |
| A CPU-bound transform (parsing, hashing, compression)       | Plain sync; parallelize with threads / `rayon` if needed                  |
| A general-purpose library's core algorithm                  | Sync, runtime-agnostic; expose async only as a thin feature-gated adapter |
| A handful of blocking calls in a CLI                        | Sync; async buys nothing                                                  |
| A long-lived service multiplexing many I/O streams          | Async at the edges, sync core                                             |

`async` makes a function return a `Future` that does nothing until polled. That is leverage when you have many waits to
interleave on one thread, and pure overhead (a state machine, `Send`/`Sync` constraints, coloured functions) when you
do not. **Do not make a CPU-bound library async** — you saddle every caller with a runtime for no concurrency win.

## Keep the core sync; push the runtime to the edge

Do not bake `tokio` into a general-purpose library. The algorithmic core should be plain Rust — testable without a
runtime, usable from any executor. Offer runtime-specific adapters behind an optional feature so the _binary_ picks the
runtime, not the library.

```rust
// ❌ tokio hard-wired into a general-purpose crate; every consumer inherits it
pub async fn checksum(path: &Path) -> std::io::Result<u64> {
    let data = tokio::fs::read(path).await?;
    Ok(data.iter().map(|&b| b as u64).sum())
}
```

```rust
// ✅ sync, portable core — no runtime in the public contract
pub fn checksum(data: &[u8]) -> u64 {
    data.iter().map(|&b| b as u64).sum()
}

// ✅ runtime coupling isolated behind an optional feature, off by default
#[cfg(feature = "tokio")]
pub mod tokio_adapter {
    use std::path::Path;

    pub async fn checksum_file(path: &Path) -> std::io::Result<u64> {
        let data = tokio::fs::read(path).await?;
        Ok(crate::checksum(&data))
    }
}
```

WHY: the async book is explicit — a library should avoid depending on a specific executor unless it genuinely needs to
spawn tasks or implement runtime-specific I/O/timers. A `tokio`-flavoured signature in your public API is a semver-level
commitment that locks out every caller on a different runtime. Avoid spawning tasks deep inside a general-purpose
library; let the caller own the executor boundary.

## `async fn` in traits: stable for internal use, careful in public APIs

`async fn` in traits (AFIT) and return-position `impl Trait` in traits (RPITIT) have been stable since Rust 1.75. For
**private / internal** traits, write `async fn` directly — it reads well and monomorphizes.

```rust
// ✅ internal trait — AFIT is fine
trait Cache {
    async fn get(&self, key: &str) -> Option<Vec<u8>>;
}
```

For a **public, runtime-agnostic** trait the bare `async fn` is a weaker contract: the returned future's auto-trait
bounds (notably `Send`) are not written in the signature, so you cannot promise `Send`, you cannot use the trait as
`dyn`, and tightening the bound later is a breaking change.

```rust
// ❌ public trait: no way to require the future is Send, no dyn dispatch
pub trait Fetch {
    async fn fetch(&self, key: &str) -> Vec<u8>;
}
```

Three ways to make the bound explicit in a public API:

```rust
// ✅ A. trait_variant generates a `Send`-bounded sibling from one definition
#[trait_variant::make(Fetch: Send)]
pub trait LocalFetch {
    async fn fetch(&self, key: &str) -> Vec<u8>;
}

// ✅ B. spell the future out — fully explicit, dyn-compatible, no macro
use core::future::Future;
pub trait Fetch {
    fn fetch(&self, key: &str) -> impl Future<Output = Vec<u8>> + Send;
}

// ✅ C. async-trait when you need `Box<dyn Fetch>` heterogeneity (boxes each future)
#[async_trait::async_trait]
pub trait Fetch {
    async fn fetch(&self, key: &str) -> Vec<u8>;
}
```

WHY: `Send` futures are required to spawn the work on a multi-threaded executor; if your public trait cannot express it,
downstream services cannot use your trait at all. `trait_variant` is the lightest-weight modern answer; reach for
`async-trait`'s boxing only when you actually need `dyn`. `Future` and `IntoFuture` are in the prelude, so no import is
needed to _call_ `.await` on these.

## Async closures (stable 1.85)

Edition-2024 toolchains have first-class async closures and the `AsyncFn`/`AsyncFnMut`/`AsyncFnOnce` traits in the
prelude. They can borrow from their captured environment across the await, which `|| async { ... }` could not.

```rust
// ✅ async closure that borrows `prefix` across the await
async fn retry<F>(mut op: F) -> Vec<u8>
where
    F: AsyncFnMut() -> Vec<u8>,
{
    loop {
        let out = op().await;
        if !out.is_empty() {
            return out;
        }
    }
}

let prefix = String::from("k:");
let _ = retry(async || fetch(&format!("{prefix}1")).await);
```

## Structured concurrency and cancellation

Run concurrent work with a clear scope so failures and cancellation are explicit.

| Need                                     | Tool                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------- |
| Await several futures, all must complete | `tokio::join!` (or `try_join!` to short-circuit on the first `Err`)       |
| Race futures, first to finish wins       | `tokio::select!` (the rest are dropped → cancelled)                       |
| A dynamic, growable set of tasks         | `tokio::task::JoinSet`                                                    |
| Cooperative cancellation signal          | `tokio_util::sync::CancellationToken` or a `select!` on a shutdown future |

```rust
// ✅ two independent fetches run concurrently; the slower one bounds latency, not the sum
let (a, b) = tokio::join!(fetch("a"), fetch("b"));
```

WHY: a future dropped before completion is _cancelled_ at its last `.await` point — no further code runs. Design so a
cancelled task leaves no half-written state. `select!` cancels the losing branches; make sure that is what you want.

## Never hold a guard or `RefCell` borrow across `.await`

This is the single most common async bug. A `std::sync::MutexGuard` (or a `RefCell` `Ref`/`RefMut`) held across an
`.await` keeps the lock while the task is suspended — it deadlocks under contention and makes the future `!Send`, so it
will not even compile on a multi-threaded executor.

```rust
// ❌ guard lives across the await point — !Send, and a deadlock waiting to happen
async fn bump(state: &std::sync::Mutex<u64>) {
    let mut g = state.lock().unwrap();
    *g += fetch_increment().await; // holds the lock across suspension
}
```

```rust
// ✅ A. drop the guard before awaiting
async fn bump(state: &std::sync::Mutex<u64>) {
    let delta = fetch_increment().await;
    *state.lock().unwrap() += delta; // lock held only for the write
}

// ✅ B. or use an async-aware mutex when the lock MUST span the await
async fn bump_async(state: &tokio::sync::Mutex<u64>) {
    let mut g = state.lock().await;
    *g += fetch_increment().await; // tokio's guard is Send and yields cooperatively
}
```

WHY: a `std::sync` lock blocks the OS thread; on an async runtime that thread is shared by other tasks, so holding it
across a yield stalls them all. Prefer dropping the guard (option A) — it keeps the critical section tiny. Use
`tokio::sync::Mutex` (option B) only when the lock truly must stay held across the await; it is slower but `Send` and
cancellation-aware. The same rule applies to `RefCell` borrows.

`clippy::await_holding_lock` and `await_holding_refcell_ref` catch these; keep them on.

## `Send` / `Sync` across await points

Everything held _live_ across an `.await` becomes part of the future's captured state, so it must be `Send` for the
future to be `Send` (and thus spawnable on a work-stealing runtime). `Rc`, `RefCell`, raw pointers, and `std`
`MutexGuard`s held across a yield all break `Send`. The fix is almost always to confine the non-`Send` value to a scope
that does not span an `.await`.

## Streams: hand-write the impl (no `gen` on stable)

For an async sequence of values use `futures::Stream`. **`gen` blocks and `gen fn` generators are still unstable on Rust
1.96** — do not emit them. Either hand-write a `Stream` (or `Iterator`) impl, or use a helper from `tokio-stream` /
`async-stream`.

```rust
// ✅ tokio_stream adapts a channel receiver into a Stream — no generator needed
use tokio_stream::wrappers::ReceiverStream;

fn events(rx: tokio::sync::mpsc::Receiver<Event>) -> impl tokio_stream::Stream<Item = Event> {
    ReceiverStream::new(rx)
}
```

WHY: emitting `gen { ... }` produces code that does not build on stable 1.96. A hand-written `poll_next`, or an existing
adapter crate, is the portable answer until generators stabilize.
