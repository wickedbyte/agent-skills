# Concurrency

Pick the model by the bottleneck — I/O-bound, CPU-bound, or isolation — then use structured concurrency within it.
Never block the event loop. On 3.14 the defaults and the available models have shifted.

## The decision matrix

The first question is always _what is the work waiting on_. Threads, async, processes, and subinterpreters are not
interchangeable; each wins for one kind of bottleneck and loses badly for the others.

| Work kind                                   | Default choice                                                     | Why                                                        | Primary risk                                     |
| ------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------- | ------------------------------------------------ |
| High-concurrency network / file I/O         | `asyncio` (Trio/AnyIO if you want backend-neutral structured APIs) | Thousands of waiting tasks, near-zero coordination cost    | A blocking call freezes the whole loop           |
| Blocking I/O via a sync library             | Threads / `asyncio.to_thread`                                      | Shared memory, familiar sync APIs, GIL released during I/O | Accidentally running CPU work under the GIL      |
| CPU-bound pure Python                       | `ProcessPoolExecutor` or `InterpreterPoolExecutor`                 | Real parallelism past the GIL                              | Serialization, startup cost, isolation semantics |
| CPU-bound native code that releases the GIL | Threads                                                            | Shared memory, low handoff overhead                        | The extension must actually release the GIL      |
| Hard fault isolation required               | Processes                                                          | OS-level isolation; a crash takes one worker               | Highest startup and handoff cost                 |

The GIL is why CPU-bound pure-Python work does **not** scale on threads: only one thread runs bytecode at a time.
Threads still help I/O because the GIL is released while a thread waits on a socket or disk. (The free-threaded build,
below, changes this — but it is not the default, so portable code must not assume it.)

## asyncio: structured concurrency with `TaskGroup`

Use `asyncio.TaskGroup` rather than loose `create_task` calls. A task group gives lexical ownership: every child task
lives inside the `async with` block, the block does not exit until all children finish, and if one task raises, the
siblings are cancelled and the failures surface together.

```python
# ❌ Detached tasks — no ownership, errors vanish, may outlive main()
import asyncio

async def main() -> None:
    asyncio.create_task(fetch_one())
    asyncio.create_task(fetch_two())
    await asyncio.sleep(1)   # hope they finished?

# ✅ Lexical scope, coordinated cancellation, aggregated failures
async def main() -> None:
    async with asyncio.TaskGroup() as tg:
        a = tg.create_task(fetch_one())
        b = tg.create_task(fetch_two())
    use(a.result(), b.result())   # both guaranteed done here
```

Bound _how long_ with `asyncio.timeout`, which cancels the body cleanly if it overruns:

```python
async def fetch_with_deadline(url: str) -> bytes:
    async with asyncio.timeout(5.0):
        return await http_get(url)
```

For large fan-out, cap concurrency with a `asyncio.Semaphore` — ten thousand simultaneous connections hurt the backend,
the OS, and you. Acquire the semaphore inside each task before doing the I/O.

## Never block the event loop

The loop is single-threaded. A synchronous call — a blocking HTTP client, a heavy computation, `time.sleep` — stalls
_every_ task until it returns. Offload sync I/O to a thread with `asyncio.to_thread`, and CPU work to an executor.

```python
# ❌ Blocks the loop; concurrency collapses to serial
import asyncio, requests

async def fetch(url: str) -> bytes:
    return requests.get(url).content   # synchronous — freezes the loop

# ✅ Run the blocking call on a worker thread
async def fetch(url: str) -> bytes:
    return await asyncio.to_thread(lambda: requests.get(url).content)
```

For CPU-bound work, hand it to a process or interpreter pool via `loop.run_in_executor`, not `to_thread` — a thread
would still contend on the GIL.

## Threads vs. processes, and the `forkserver` default

On Unix (except macOS), 3.14 makes **`forkserver` the default** `multiprocessing` start method; `fork` is no longer the
default anywhere. `forkserver` spawns workers from a clean server process, which sidesteps the well-known hazard of
forking a multithreaded process (inherited locks in an undefined state, deadlocks). The practical consequences:

- Worker arguments and the target function must be **picklable and importable** — code that leaned on inherited mutable
  globals or open file descriptors from `fork` will break or silently misbehave.
- Startup is a little slower. Pass state explicitly via worker arguments or an `initializer`, not ambient globals.

```python
# ✅ Explicit state handoff survives forkserver (and is testable)
from concurrent.futures import ProcessPoolExecutor

def init_worker(table_bytes: bytes) -> None:
    global TABLE
    TABLE = load_table(table_bytes)

def work(key: str) -> int:
    return TABLE[key]

with ProcessPoolExecutor(initializer=init_worker, initargs=(table_bytes,)) as ex:
    results = list(ex.map(work, keys))
```

If you genuinely need `fork` (e.g. to inherit a large read-only structure cheaply), request it **explicitly** and
deliberately — it is an OS-specific opt-in, not a baseline assumption:

```python
import multiprocessing as mp
ctx = mp.get_context("fork")   # explicit, intentional, Unix-only
```

For large binary state, prefer `multiprocessing.shared_memory` over copying it into every worker.

## Subinterpreters: `InterpreterPoolExecutor` (PEP 734)

3.14 promotes subinterpreters to a first-class stdlib tool via `concurrent.interpreters` and
`concurrent.futures.InterpreterPoolExecutor`. Each worker runs in its own thread _and_ its own interpreter, giving a
middle ground: stronger isolation than threads (separate module state, separate GIL on builds that have per-interpreter
GILs) with lower overhead than spawning OS processes.

```python
# ✅ CPU-bound pure Python with in-process isolation, no separate OS process per worker
from concurrent.futures import InterpreterPoolExecutor

def cpu_heavy(n: int) -> int:
    return sum(i * i for i in range(n))

with InterpreterPoolExecutor() as ex:
    totals = list(ex.map(cpu_heavy, [10_000_000] * 8))
```

Reach for subinterpreters when task boundaries are already explicit and the arguments/results are simple and
serializable. Use **processes** when you need OS-level fault isolation or mature ecosystem support; use **threads** when
the work is blocking I/O or GIL-releasing native code.

## The free-threaded build: an emerging option, not a default

The free-threaded (no-GIL) build is **officially supported** as of 3.14 (PEP 779) — but it is a **separate, optional
build** (`--disable-gil`, reported via `Py_GIL_DISABLED`), not the interpreter most users run. On it, threads achieve
true parallelism for CPU-bound Python, but it carries roughly **5–10% single-threaded overhead** and not every C
extension is compatible yet.

Treat it as a deployment choice to measure, not an assumption to bake in:

- **Do not** write portable code that assumes threads scale CPU-bound work — on the default GIL build they will not.
- **Do** keep your concurrency boundaries explicit and your shared state guarded; that code runs correctly on both
  builds and is ready if you adopt free-threading later.
- Verify at runtime when it matters: `sys._is_gil_enabled()` (or check `sysconfig.get_config_var("Py_GIL_DISABLED")`).

## Aggregated failures: `ExceptionGroup` and `except*`

Concurrent operations fail concurrently — a `TaskGroup` may have several children raise at once. 3.11+ models this with
`ExceptionGroup`, and `TaskGroup` raises one automatically. Handle the constituent exceptions by type with `except*`,
which runs each matching handler over the matching subgroup:

```python
async def gather_all() -> None:
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(may_timeout())
            tg.create_task(may_404())
    except* TimeoutError as eg:
        log.warning("%d task(s) timed out", len(eg.exceptions))
    except* HTTPError as eg:
        log.error("%d task(s) failed HTTP", len(eg.exceptions))
```

`except*` clauses do not short-circuit each other the way a chain of plain `except` does — every clause gets a chance at
its matching subgroup, and anything unmatched re-raises as a residual group. Raise your own `ExceptionGroup` when you
aggregate failures by hand outside a `TaskGroup`.
