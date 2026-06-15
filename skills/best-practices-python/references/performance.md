# Performance

Measure first; fix the algorithm and data layout before anything clever. The biggest wins are structural — the wrong
complexity, the wrong container, a million objects where a buffer would do — not micro-tweaks.

## Measure first — the whole doctrine

Do not change code "for performance" without a measurement that says it is the bottleneck and a re-measurement that says
your change helped. Guesswork loses to data, and most "obvious" optimizations are noise or regressions.

Use the right tool for the question:

| Tool                   | Question it answers                                      | Notes                                                                                  |
| ---------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `timeit`               | How long does this small snippet take?                   | Disables GC by default for comparability; trust the **minimum** of repeated runs       |
| `pyperf`               | Is this microbenchmark result _stable and reproducible_? | CPU pinning, system tuning, JSON output — use it for CI gates and cross-machine claims |
| `cProfile` / `profile` | Which functions accumulate the time?                     | Deterministic, built-in, higher overhead                                               |
| `py-spy`               | What is this _running_ process doing right now?          | Sampling, out-of-process, no restart — safe in production                              |
| Scalene                | Where are CPU **and memory** going?                      | Mixed CPU/memory attribution                                                           |

```python
import timeit

def bench(stmt_fn) -> float:
    timer = timeit.Timer(stmt_fn)
    loops, _ = timer.autorange()           # find a loop count that runs long enough
    runs = timer.repeat(repeat=7, number=loops)
    return min(runs) / loops               # minimum = least disturbed by scheduler noise
```

Collect more than an average — cold vs. warm latency, p50/p95/p99 for services, and a memory delta (`tracemalloc` or
process RSS). Benchmark the _exact build_ you deploy: interpreter flags, ABI, and free-threaded vs. GIL all move the
numbers. If a result is not measured on the target build, hardware, and workload, treat the speedup as unproven and
keep the clearer code.

## Algorithmic complexity and container choice

The largest, most durable wins come from changing the complexity class, not the spelling. Pick the container that makes
the dominant operation cheap:

| Operation                    | Right structure                           | Wrong default                     |
| ---------------------------- | ----------------------------------------- | --------------------------------- |
| Membership test / dedup      | `set` (O(1))                              | `x in some_list` (O(n))           |
| Lookup by key                | `dict` (O(1))                             | linear scan over a list           |
| FIFO queue / both-ends       | `collections.deque` (`popleft` O(1))      | `list.pop(0)` (O(n))              |
| Priority queue / top-k       | `heapq`                                   | sorting the whole list repeatedly |
| Insert/search in sorted data | `bisect`                                  | re-sorting after each insert      |
| Bulk numeric / binary data   | `array`, `bytearray`, `memoryview`, NumPy | a list of boxed Python objects    |

```python
# ❌ O(n) per lookup — quadratic over the loop
seen = []
for item in stream:
    if item.id in seen:        # linear scan every iteration
        continue
    seen.append(item.id)

# ✅ O(1) membership
seen: set[str] = set()
for item in stream:
    if item.id in seen:
        continue
    seen.add(item.id)
```

```python
# ❌ list as a queue — pop(0) shifts every element
queue = list(items)
while queue:
    handle(queue.pop(0))       # O(n) each pop

# ✅ deque — O(1) at both ends
from collections import deque
queue = deque(items)
while queue:
    handle(queue.popleft())
```

Lean on the C-implemented stdlib — `itertools`, `functools`, `operator`, `functools.lru_cache` for memoization — before
hand-writing loops; it both expresses intent and moves work below the Python interpreter.

## Data layout: slots and contiguous storage

Per-instance `__dict__` is the hidden cost of high-cardinality objects. `@dataclass(slots=True)` (or `__slots__` on a
plain class) drops the dict, shrinking memory and speeding attribute access — exactly what you want for the millions of
small records in a hot path.

```python
# ❌ Per-instance dict for a many-instance record
from dataclasses import dataclass

@dataclass
class Point:
    x: float
    y: float
    z: float

# ✅ slots: no __dict__, less memory, faster attribute access
@dataclass(slots=True)
class Point:
    x: float
    y: float
    z: float
```

`frozen=True` adds rigor at a tiny init-time cost (the generated `__init__` goes through `object.__setattr__`). For
bulk numeric or binary data, the bigger lever is leaving Python objects behind entirely: store the data in a contiguous
buffer (`array.array`, `bytearray`, NumPy) and operate on it with a `memoryview` or vectorized ops, so you pay one
dispatch per _batch_ rather than one per _element_. (See `data-modeling.md` for the record-type decision.)

## Generators and laziness to bound memory

Materializing a giant list to consume it once wastes memory proportional to the input. A generator streams one item at a
time, so memory stays flat regardless of input size.

```python
# ❌ Builds the whole list in memory just to sum it
def total(path: Path) -> int:
    lines = [int(line) for line in path.read_text().splitlines()]
    return sum(lines)

# ✅ Streams — constant memory, no intermediate list
def total(path: Path) -> int:
    with path.open() as f:
        return sum(int(line) for line in f)
```

Use a generator expression or `yield` for large or unbounded sequences and pipelines; reach for `itertools.islice`,
`chain`, `groupby` to compose them lazily. Keep a list comprehension when you genuinely need the materialized result
(random access, multiple passes, `len`).

## Vectorize numeric hot paths with NumPy

A Python loop over numbers pays interpreter overhead per element. When the data is large and numeric, push the loop into
NumPy's compiled, vectorized kernels:

```python
# ❌ Per-element Python loop with boxed floats
def axpy(a: float, xs: list[float], ys: list[float]) -> list[float]:
    return [a * x + y for x, y in zip(xs, ys)]

# ✅ One vectorized operation over contiguous float64 arrays
import numpy as np

def axpy(a: float, xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
    return a * xs + ys
```

The win is real only when the arrays are large enough to amortize the call; for a handful of values the loop is fine.
Convert to `np.asarray` once at the boundary, not repeatedly inside a loop.

## 3.14 GC changes — discard stale tuning

3.14 reworked the cyclic garbage collector: **generation 1 was removed** from the model and **`threshold2` is now
ignored**. The familiar `gc.set_threshold(700, 10, 10)` incantation copied from older codebases is now partly
meaningless and signals stale assumptions.

```python
# ❌ Pre-3.14 folklore — the second/third args no longer mean what they did
import gc
gc.set_threshold(700, 10, 10)   # threshold2 is ignored on 3.14

# ✅ If you tune at all, tune from observed stats on the actual 3.14 build
import gc
before = gc.get_stats()
run_representative_workload()
print({"stats_delta": (before, gc.get_stats()), "thresholds": gc.get_threshold()})
```

Most code should not touch the GC at all. The one durable pattern is pre-`fork` memory sharing — `gc.disable()` in the
parent, `gc.freeze()` immediately before fork, `gc.enable()` early in the child — and that only applies when you have
deliberately chosen a `fork` start method (see `concurrency.md`).

## Native acceleration — only after profiling

Dropping to native code is the last resort, taken only after a profiler names a specific kernel as the dominant cost and
algorithm/layout fixes are exhausted.

| Option                     | Best for                                     | Cost                                   |
| -------------------------- | -------------------------------------------- | -------------------------------------- |
| Cython (typed memoryviews) | Python-like numeric kernels and tight loops  | CPython-centric, generated C to manage |
| Rust via PyO3 + maturin    | Safety-focused native modules, `abi3` wheels | Rust toolchain, FFI boundary design    |
| C extension / Stable ABI   | Hottest kernels, widely distributed wheels   | Highest complexity, refcount hazards   |

Two rules dominate: **do not cross the FFI boundary per scalar** (batch the call), and **prefer the least powerful tool
that fixes the measured bottleneck**. A `memoryview` over a `bytearray` often removes the hotspot without any native
code at all.

## The experimental JIT: off by default

3.14 ships an experimental JIT, but it is **disabled by default** and not guaranteed to speed up your workload. Do not
design around it, tune for it, or assume its presence in portable code. If you want to evaluate it, do so as a measured,
build-specific experiment with the same `pyperf` discipline as any other change — and keep the code correct and clear
without it.

## What not to micro-optimize

The wins that matter, in order: the wrong algorithm (O(n²) where O(n) exists), the wrong data structure (a scan where a
`dict`/`set` works), I/O in a loop instead of batched or concurrent, and per-element allocation on a measured hot path.
Below that, a clever expression rewrite is a few percent at best and easily regresses across versions. Profile, fix the
bottleneck, re-measure — and if the change does not hold up, revert it for clarity.
