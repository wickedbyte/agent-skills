# Control Flow and Errors

EAFP vs LBYL, building a specific exception hierarchy, `ExceptionGroup` / `except*`, parenthesized `except`, `match` /
`case`, comprehensions vs generators, context managers, the mutable-default trap, and why `assert` is not validation.

## Contents

- EAFP over LBYL — and the TOCTOU argument
- Build a specific exception hierarchy
- Catch narrowly; never bare `except`
- `ExceptionGroup` and `except*`; parenthesized `except`
- `match` / `case` over `isinstance` chains
- Comprehensions vs generators
- Context managers for every resource
- The mutable-default-argument trap
- Never `assert` for runtime validation

## EAFP over LBYL — and the TOCTOU argument

EAFP ("easier to ask forgiveness than permission") tries the operation and catches the specific failure. LBYL ("look
before you leap") pre-checks. Prefer EAFP.

```python
# ❌ LBYL — two lookups, and a race between them
if key in cache:
    return cache[key]
return load_and_cache(key)

# ✅ EAFP — one lookup, no race
try:
    return cache[key]
except KeyError:
    return load_and_cache(key)
```

WHY beyond style: the LBYL check and the use are two separate operations, and the world can change between them — the
**time-of-check / time-of-use (TOCTOU)** race. `if path.exists(): open(path)` can still raise: the file may be deleted
in the gap. EAFP collapses check and use into one atomic attempt, so there is no gap to race. It is also faster on the
happy path, which is the common path. Use LBYL only when the check is genuinely cheaper than the failure and there is no
shared mutable state (e.g. validating a number range before a costly computation).

## Build a specific exception hierarchy

Inherit from the **most specific built-in** that fits, drop a redundant `Error` suffix when the base already says it,
put context in the constructor, and chain with `raise ... from`.

| The failure is…                            | Inherit from                                 |
| ------------------------------------------ | -------------------------------------------- |
| A bad value / argument                     | `ValueError`                                 |
| A failed lookup (missing key/index/name)   | `LookupError` (or `KeyError` / `IndexError`) |
| An operation invalid for the current state | `RuntimeError`                               |
| A wrong type                               | `TypeError`                                  |
| Missing OS resource, I/O failure           | `OSError` and its subclasses                 |

```python
# ❌ Generic, contextless, uninformative
raise Exception(f"not found: {user_id}")

# ✅ Specific base, no redundant suffix, context in the constructor
class UserNotFound(LookupError):
    def __init__(self, user_id: str) -> None:
        super().__init__(f"No user with id {user_id!r}")
        self.user_id = user_id

def load_user(user_id: str) -> User:
    try:
        row = db.fetch_one("SELECT ...", user_id)
    except DatabaseError as e:
        raise UserNotFound(user_id) from e   # chain: preserves the original cause
    return User.from_row(row)
```

WHY inherit from a specific built-in: a caller doing `except LookupError` catches your `UserNotFound` for free, and
generic `except ValueError` handlers in stdlib and libraries keep working. WHY drop the suffix: the base class already
communicates the category — `UserNotFound(LookupError)` reads better than `UserNotFoundError`. WHY `from e`: it sets
`__cause__`, so the traceback shows both the low-level `DatabaseError` and your domain exception. Use `from None` only
to deliberately suppress an irrelevant cause.

## Catch narrowly; never bare `except`

```python
# ❌ Swallows everything — KeyboardInterrupt, SystemExit, real bugs
try:
    value = parse(raw)
except:
    value = None

# ❌ Still far too broad
except Exception:
    value = None

# ✅ Catch the one thing you can handle; let the rest propagate
try:
    value = parse(raw)
except ValueError:
    value = None
```

WHY: a bare `except` (or `except Exception`) hides programming errors, masks `KeyboardInterrupt`/`SystemExit`, and turns
a precise failure into a silent wrong answer. Catch the narrowest type you can actually recover from; everything else
should crash loudly where it can be diagnosed.

## `ExceptionGroup` and `except*`; parenthesized `except`

When multiple failures happen together — concurrent tasks, a batch of validations — raise an `ExceptionGroup` and handle
its members with `except*` (3.11+). Each `except*` clause runs for the matching members; unmatched members re-raise.

```python
def validate(form: Form) -> None:
    errors: list[Exception] = []
    if not form.name:    errors.append(ValueError("name required"))
    if form.age < 0:     errors.append(ValueError("age must be >= 0"))
    if errors:
        raise ExceptionGroup("invalid form", errors)

try:
    run_concurrent_tasks()          # e.g. an asyncio.TaskGroup that aggregates failures
except* ConnectionError as eg:
    for exc in eg.exceptions:
        log.warning("connection failed: %s", exc)
except* TimeoutError as eg:
    retry_later(eg)
```

To catch _several unrelated_ exception types in one ordinary clause, 3.14 (PEP 758) allows parenthesis-free syntax — but
keep the parentheses when you also bind with `as`:

```python
except (ValueError, TypeError):        # classic, always valid
    ...
except ValueError, TypeError:          # 3.14 parenthesis-free — only when NOT binding
    ...
```

WHY `except*`: a `TaskGroup` can fail with many exceptions at once; a flat `except` could only ever see one.
`ExceptionGroup` keeps them all, and `except*` lets you triage by type without losing the rest.

## `match` / `case` over `isinstance` chains

Structural pattern matching dispatches on _shape_ — captures, guards, and mapping/sequence/class patterns — and reads
far better than a ladder of `isinstance`/`elif`.

```python
# ❌ isinstance ladder
def area(shape: Shape) -> float:
    if isinstance(shape, Circle):
        return math.pi * shape.r ** 2
    elif isinstance(shape, Rect):
        return shape.w * shape.h
    raise ValueError(shape)

# ✅ class patterns bind attributes by position/keyword; guards add conditions
def area(shape: Shape) -> float:
    match shape:
        case Circle(r=r):
            return math.pi * r ** 2
        case Rect(w=w, h=h) if w > 0 and h > 0:
            return w * h
        case _:
            raise ValueError(f"unknown shape: {shape!r}")

# Mapping and sequence patterns destructure data shapes:
match event:
    case {"type": "click", "x": x, "y": y}:   # mapping pattern, binds x and y
        handle_click(x, y)
    case [first, *rest]:                      # sequence pattern
        handle_batch(first, rest)
```

WHY: each `case` both tests and destructures in one line, guards (`if …`) attach conditions to a branch, and pairing the
final fallthrough with `assert_never` (see `typing.md`) turns missing variants into type-check errors. Keep an
`isinstance` for a single binary check; reach for `match` when there are three or more shape-based branches.

## Comprehensions vs generators

A comprehension builds the whole collection in memory; a generator yields lazily, one item at a time.

```python
total = sum(line.amount for line in ledger)       # ✅ generator — never materializes a list
names = [u.name for u in users if u.active]        # ✅ comprehension — small, reused result

def read_records(path: Path) -> Iterator[Record]:  # ✅ yield for a streaming pipeline
    with path.open() as f:
        for line in f:
            yield Record.parse(line)
```

Use a **comprehension** when the result is small and you will index or reuse it. Use a **generator expression** or a
`yield` function when the sequence is large, infinite, or fed straight into a consumer (`sum`, `any`, `max`, a `for`
loop) — it bounds memory and short-circuits. Do not force a comprehension when a plain loop with side effects is
clearer; comprehensions are for producing a value, not for running effects.

## Context managers for every resource

Never hand-pair acquire and release. Use `with` for files, locks, connections, and transactions.

```python
with path.open(encoding="utf-8") as f:      # ✅ closed even if the body raises
    data = f.read()

with lock, connection:                       # ✅ multiple managers on one line
    connection.execute(...)

from contextlib import suppress, contextmanager, ExitStack

with suppress(FileNotFoundError):            # ✅ the "ignore this specific error" idiom
    tmp.unlink()

@contextmanager                               # ✅ your own setup/teardown
def timed(label: str) -> Iterator[None]:
    start = perf_counter()
    try:
        yield
    finally:
        log.info("%s took %.3fs", label, perf_counter() - start)

with ExitStack() as stack:                    # ✅ a dynamic number of resources
    files = [stack.enter_context(p.open()) for p in paths]
    merge(files)                              # all closed on exit, in reverse order
```

WHY: `with` guarantees the teardown runs on every exit path — normal return, exception, early `break`. Manual
`open()`/`close()` leaks on the exception path. `suppress` replaces the noisy `try/except/pass`; `@contextmanager` turns
a generator into a manager; `ExitStack` manages a count of resources you do not know until runtime.

## The mutable-default-argument trap

A default argument is evaluated **once**, at function-definition time — so a mutable default is shared across every
call.

```python
# ❌ The same list persists and accumulates across calls
def append_item(item: int, items: list[int] = []) -> list[int]:
    items.append(item)
    return items
# append_item(1) -> [1]; append_item(2) -> [1, 2]  (!)

# ✅ Default to None, construct inside
def append_item(item: int, items: list[int] | None = None) -> list[int]:
    items = items if items is not None else []
    items.append(item)
    return items
```

WHY: the list object is created when `def` runs, not when the function is called, so one object backs every default-arg
invocation. The `None`-sentinel fix makes "no argument given" explicit and builds a fresh container per call. The same
trap applies to `dict`, `set`, and any other mutable default.

## Never `assert` for runtime validation

`assert` statements are stripped entirely when Python runs with `-O` (common in production). An `assert` used as a real
check therefore _vanishes_ in the environment that needs it most.

```python
# ❌ Disappears under python -O — the check is simply gone in production
def withdraw(account: Account, amount: int) -> None:
    assert amount > 0, "amount must be positive"
    assert account.balance >= amount

# ✅ Explicit, always-on validation with a specific exception
def withdraw(account: Account, amount: int) -> None:
    if amount <= 0:
        raise ValueError("amount must be positive")
    if account.balance < amount:
        raise InsufficientFunds(account.id, amount)
```

`assert` is for _internal invariants you believe can never be false_ — documenting an assumption for other developers
and the type checker, where its disappearance under `-O` is acceptable. It is never for validating arguments, user
input, or any condition a caller could actually trigger.
