---
name: best-practices-python
description: >-
    Use when writing, modifying, or reviewing Python code (.py, .pyi files) — including functions, classes, dataclasses,
    enums, protocols, type hints, exceptions, async code, tests, or any Python-emitting task. Applies to every Python
    task and targets Python 3.14. Triggers for type-hints-everywhere with modern syntax (`list[int]`, `X | None`, PEP
    695 generics `def f[T]`), frozen dataclasses as value objects, `Protocol` over ABCs, `StrEnum`/`IntEnum` over string
    constants, EAFP over LBYL, specific exception hierarchies and `except*`, `pathlib` over `os.path`, f-strings and 3.14
    t-strings, deferred annotations, comprehensions and generators, and the uv + Ruff + type-checker toolchain. Use this
    even when the user does not explicitly mention Python style or say "Pythonic".
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# How to Write Python

This skill captures an opinionated, framework-agnostic Python style targeting the language as it stands in mid-2026
(Python 3.14, uv for project management, Ruff for lint + format, a strict type checker in CI, pytest). Follow it for any
Python work.

> **Tool versions move faster than this document.** uv, Ruff, mypy/pyright/ty, and pytest release frequently. This
> skill deliberately does **not** pin their version numbers. Use whatever the project already depends on; when adding
> tooling to a project that has none, **verify the current stable release yourself** (check PyPI / the tool's releases)
> rather than trusting a number — the conventions below hold across recent releases. (Python 3.14 is the deliberate
> language target, not a tool version.)

## The One Idea

**Python is a dynamically-typed language that you should write as if it were statically typed.** The interpreter will
run almost anything; the leverage of modern Python comes from constraining that freedom on purpose — annotate every
boundary, name every domain concept as a type, make immutability the default and mutation a deliberate exception, and
let the tools (a type checker, a linter, a formatter) enforce the contract the runtime won't. The 3.14 ecosystem rewards
this: deferred annotations make rich type hints free at import time, dataclasses / enums / protocols give domain
concepts cheap structure, and the Rust-based toolchain (uv, Ruff, ty) makes strict checking fast enough to run on every
keystroke. "Pythonic" and "rigorous" are no longer in tension — the same habits buy you readability _and_ correctness.

Two consequences shape everything below:

1. **Untyped code is legacy code.** A signature without annotations is a contract the checker — and the next reader —
   cannot verify. Type everything; run a checker in CI and treat its output as build-breaking.
2. **Idiom is the point, not a veneer.** EAFP, comprehensions, context managers, the enum family, and `match` exist
   because they express intent more directly than the imperative alternative — not because they are shorter.

## Framework Conventions Take Precedence

This skill is **framework-agnostic**; a framework's own conventions win wherever they conflict. A Django model is a
mutable `models.Model` subclass, not a frozen dataclass; you use Django's ORM, settings, `logging` config, forms, and
class-based views as Django intends. A FastAPI app models request/response bodies as Pydantic models and
wires dependencies through `Depends(...)`, not hand-rolled Protocols. SQLAlchemy, Pydantic, attrs, and Django REST
Framework each have their own declaration styles. Follow the framework (and the project's established patterns) first;
apply this skill's guidance to everything the framework leaves open — your domain logic, plain value objects, enums,
exceptions, typing discipline, and tooling. Do not rewrite working framework-idiomatic code toward these defaults just
because they differ.

## When to Use This Skill

Use it for any of:

- Authoring or editing `.py` / `.pyi` files — functions, classes, modules, packages
- Designing value objects, enums, protocols, exception hierarchies
- Writing async code, CLIs, services, libraries, data pipelines, tests
- Setting up or changing `pyproject.toml`, Ruff config, type-checker config, the uv lockfile
- Reviewing Python for missing types, legacy `typing` imports, mutable defaults, bare `except`, or un-Pythonic loops
- Modernizing a Python 3.9–3.12 codebase toward 3.14 idioms

Do not use it for: Jupyter notebook exploration where throwaway cells are intentional, or generated code you do not own.

## Core Defaults — apply unless the task gives a specific reason not to

### 1. Annotate everything; opt fully into the type system

Every function signature and every public attribute carries a type. Run a type checker (pyright or mypy) in CI in strict
mode and treat findings as errors, not suggestions.

```python
def published_posts(status: PostStatus, limit: int = 20) -> list[Post]: ...
```

### 2. Modern type syntax — built-in generics, `X | None`, PEP 695 parameters

Never import `List` / `Dict` / `Optional` / `Union` from `typing`. Write `list[int]`, `dict[str, int]`, `str | None`.
For generics use the PEP 695 inline form, not the legacy `TypeVar` / `Generic[T]` dance:

```python
def first[T](xs: list[T]) -> T | None:
    return xs[0] if xs else None

class Box[T]:
    def __init__(self, value: T) -> None: ...

type Json = str | int | float | bool | None | list["Json"] | dict[str, "Json"]
```

See `references/typing.md` for `Protocol`, `TypedDict`, `Literal`, `NewType`, `Final`, `Self`, and boundary validation.

### 3. Frozen dataclasses are the default value object

`@dataclass(frozen=True, slots=True)` gives immutability, hashability, equality, and a per-instance memory win in one
decorator. Validate in `__post_init__`; evolve with `dataclasses.replace()` (the wither pattern), never mutation.

```python
@dataclass(frozen=True, slots=True)
class EmailAddress:
    value: str

    def __post_init__(self) -> None:
        if "@" not in self.value:
            raise ValueError(f"Invalid email: {self.value}")
```

### 4. Pick the record type deliberately

Frozen + slots dataclass for most value objects; `NamedTuple` when you also need tuple-unpacking or a lightweight
positional key; a plain (possibly slotted) class only when mutation is genuinely the point. Reach for `attrs` or
Pydantic only when you need converters or runtime parsing beyond `__post_init__`. See `references/data-modeling.md`.

### 5. Default to immutability; make mutation explicit

Prefer `tuple` / `frozenset` over `list` / `set` for data that should not change, and frozen dataclasses over mutable
ones. Mutable state should be named as such and confined behind explicit methods, not leaked through shared references.

### 6. Use the enum family for closed sets of values

`StrEnum` for values that cross an API/DB boundary (they compare equal to plain strings), `IntEnum` for wire/bitmask
integers, plain `Enum` otherwise. Use `auto()` for opaque values and put behavior on the enum as methods.

```python
from enum import StrEnum, auto

class PostStatus(StrEnum):
    DRAFT = auto()      # "draft"
    PUBLISHED = auto()  # "published"

    def is_visible(self) -> bool:
        return self is PostStatus.PUBLISHED
```

### 7. Define interfaces as `Protocol`, not `ABC`

Structural typing decouples the implementation from the abstraction — any class with the right shape conforms, with no
inheritance or registration. Name protocols as capability nouns (`RequestContextProvider`, no `Protocol` suffix). Add
`@runtime_checkable` only when you actually need `isinstance`. Reserve `ABC` for when you want to _share
implementation_.

### 8. EAFP over LBYL

Try the operation and catch the specific exception rather than pre-checking. It is faster on the happy path and avoids
time-of-check/time-of-use races.

```python
try:
    return cache[key]
except KeyError:
    return load_and_cache(key)
```

### 9. Build a specific exception hierarchy; never raise or catch bare `Exception`

Inherit from the most specific built-in (`ValueError`, `LookupError`, `RuntimeError`), drop the redundant `Error` suffix
when the base already says it, and put context in the constructor. Catch narrowly. For concurrent or aggregated failures
use `ExceptionGroup` + `except*` (3.11+). See `references/control-flow-and-errors.md`.

### 10. Comprehensions for transformation, generators for streaming

Prefer a comprehension over a manual `append` loop; use a generator expression or `yield` for large or lazy sequences to
bound memory. Do not force a comprehension when a plain loop with side effects is clearer.

### 11. `pathlib` over `os.path`; f-strings for display; t-strings where output is escaped

`Path("data") / "in.txt"`, not `os.path.join`. f-strings for interpolation. Use 3.14 **t-strings** (`t"..."` →
`string.templatelib.Template`) for SQL / HTML / shell, where a processing layer must escape the interpolated parts —
they hand you the static and interpolated pieces separately, which is what prevents injection.

### 12. Context managers for every resource

`with open(...)`, locks, connections, `contextlib.suppress`, and `@contextlib.contextmanager` for your own setup /
teardown. Never hand-pair acquire and release.

### 13. Depend on abstractions explicitly; inject them

Pass collaborators (typed as Protocols) into constructors and functions instead of constructing them inline or reaching
for module globals and singletons. This is what makes Protocol-based test doubles possible without a mock library. See
`references/protocols-and-di.md`.

### 14. `src/`-layout project with a single `pyproject.toml`

Code under `src/<package>/`, PEP 621 metadata plus all tool config (Ruff, type checker, pytest) in `pyproject.toml`, a
committed `uv.lock`. No `setup.py`, no `requirements.txt` as the source of truth. Use dependency groups for dev / test
so
they do not leak into runtime metadata. See `references/project-and-tooling.md`.

### 15. Rely on deferred annotations (3.14) — no quotes, no `__future__` import

Annotations are lazily evaluated, so `def f(node: TreeNode) -> TreeNode:` works before `TreeNode` is fully defined, with
no `"TreeNode"` quoting and no `from __future__ import annotations`. If you introspect annotations at runtime (DI,
serializers, decorators), go through `annotationlib.get_annotations(obj, format=...)`, never raw `__annotations__` or
`eval()`. (Self-referential aliases in a `type` statement still need quoting, as shown in default 2.)

### 16. `match`/`case` for structural dispatch; never a mutable default argument

Pattern-match over shapes and variants instead of long `isinstance` chains. And default to `None`, then construct inside
the function — `def f(items: list[int] | None = None): items = items if items is not None else []` — because
`def f(items=[])` shares one list across every call.

## Quick Triage Table

| Situation                                               | Default choice                                                     |
| ------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------- |
| Modeling an immutable value                             | `@dataclass(frozen=True, slots=True)`, validate in `__post_init__` |
| Producing a changed copy                                | `dataclasses.replace(obj, field=new)`                              |
| Modeling a lightweight positional record / hashable key |
| `NamedTuple`                                            |
| Modeling mutable state                                  | Plain class (add `slots=True`) with explicit methods               |
| Modeling a fixed set of values                          | `StrEnum` (crosses a boundary) / `IntEnum` / `Enum` + `auto()`     |
| Defining an interface                                   | `Protocol` (structural); `ABC` only to share implementation        |
| Generic function or class                               | PEP 695: `def f[T](...)`, `class C[T]:`, `type Alias = ...`        |
| Optional value                                          | `X                                                                 | None`(not`Optional[X]`) |
| Looking something up that may be missing                | EAFP: `try` / `except KeyError`                                    |
| Signaling an error                                      | Raise a specific subclass of the right built-in                    |
| Aggregated / concurrent failures                        | `raise ExceptionGroup(...)`; handle with `except*`                 |
| Transforming a sequence                                 | Comprehension; generator if large or lazy                          |
| Filesystem paths                                        | `pathlib.Path`                                                     |
| Interpolating into SQL / HTML / shell                   | t-string (`t"..."`) processed by an escaping layer                 |
| A runtime precondition                                  | `if not ok: raise ...` — **never** `assert` (stripped under `-O`)  |
| Branching over variant shapes                           | `match` / `case`                                                   |

## Reference Files

Read the relevant file when the SKILL.md guidance leaves a judgment call open:

- `references/typing.md` — Built-in generics, `X | None`, PEP 695 generics and the `type` statement, `Protocol` /
  `TypedDict` / `Literal` / `NewType` / `Self` / `Final`, deferred-annotation semantics and `annotationlib`,
  boundary-validation discipline.
- `references/data-modeling.md` — Value objects: frozen dataclass vs `NamedTuple` vs plain vs `attrs`/Pydantic decision
  table, `slots` / `frozen` / `__post_init__`, the `replace()` wither pattern, the full enum family (`StrEnum` /
  `IntEnum` / `auto` / `@member`).
- `references/protocols-and-di.md` — Structural typing over nominal inheritance, `runtime_checkable`, when ABCs still
  win, explicit dependency injection, Protocol-based test doubles.
- `references/control-flow-and-errors.md` — EAFP vs LBYL, custom exception hierarchies, `ExceptionGroup` / `except*`,
  `match` / `case`, comprehensions vs generators, context managers, the mutable-default trap.
- `references/strings-and-io.md` — f-strings vs t-strings (PEP 750) and injection-safe templating, `pathlib`, buffered /
  `readinto` / `sendfile` / `mmap` zero-copy I/O, `logging` over `print`.
- `references/concurrency.md` — The CPU-vs-I/O-vs-isolation decision matrix, `asyncio.TaskGroup` / structured
  concurrency, threads vs processes (the `forkserver` default), `InterpreterPoolExecutor` / subinterpreters, the
  free-threaded build's trade-offs.
- `references/performance.md` — Measure-first doctrine (`timeit` / `pyperf` / profilers), data layout (`slots`, `array`
  / `bytearray` / `memoryview`, NumPy), container choice (`deque` / `heapq` / `bisect` / set membership), 3.14 GC
  changes, native-acceleration trade-offs.
- `references/project-and-tooling.md` — `src/` layout, `pyproject.toml`, the uv workflow and lockfile, Ruff config and
  rule sets, type-checker choice (pyright/mypy vs the faster ty/pyrefly), pytest patterns, CI matrix, packaging.
- `references/security.md` — No `assert` for runtime checks, `secrets` / `hmac.compare_digest`, `ast.literal_eval` over
  `eval`, `ssl.create_default_context`, safe deserialization (no bare `pickle` on untrusted data).

## Common Mistakes (and the fix)

| Mistake                                                  | Fix                                                                      |
| -------------------------------------------------------- | ------------------------------------------------------------------------ |
| `from typing import List, Dict, Optional`                | Built-in generics + `\|`: `list`, `dict`, `X \| None`                    |
| `TypeVar('T')` + `Generic[T]`                            | PEP 695: `def f[T](...)`, `class C[T]:`, `type X = ...`                  |
| Passing `dict`s around as ad-hoc structs                 | Frozen `@dataclass(frozen=True, slots=True)` value objects               |
| `def f(x=[])` / `def f(x={})`                            | `def f(x: list \| None = None): x = x if x is not None else []`          |
| `assert user.is_admin` as a real check                   | `if not user.is_admin: raise PermissionError(...)` (`-O` strips asserts) |
| `if k in d: v = d[k]` (LBYL)                             | EAFP: `try: v = d[k]` / `except KeyError: ...`                           |
| `except Exception:` / bare `except:`                     | Catch the specific type; build a hierarchy; `except*` for groups         |
| String constants in a "constants" class                  | `StrEnum` / `IntEnum` / `Enum` with `auto()` and methods                 |
| `ABC` + `@abstractmethod` for a one-method interface     | `Protocol` (structural); `@runtime_checkable` only if needed             |
| `os.path.join(...)`, manual `open` / `close`, `"%s" % x` | `pathlib.Path`, `with`, f-strings (t-strings where escaping)             |
| `list` used as a FIFO queue (`q.pop(0)`)                 | `collections.deque` + `popleft()` (O(1))                                 |
| Raw `__annotations__` / `eval()` introspection           | `annotationlib.get_annotations(obj, format=...)` (3.14)                  |
| `from __future__ import annotations` for forward refs    | Unneeded on 3.14 — annotations are deferred by default                   |

## Modernization Order for an Existing Codebase

Do not change everything at once:

1. Adopt the tooling: `uv` for the environment, Ruff (`check` + `format`) and a type checker in CI.
2. Run `ruff check --fix` with the `UP` (pyupgrade) rules to mechanically modernize syntax (`list[int]`, `X | None`).
3. Add annotations to every public signature; turn on strict type-checking and drive errors to zero file by file.
4. Replace string-constant bags with enums; replace ad-hoc dicts with frozen dataclasses.
5. Convert `ABC` interfaces with no shared implementation to `Protocol`s.
6. Replace mutable defaults, bare `except`, and `assert`-as-validation; tighten exception types.
7. Drop `from __future__ import annotations` and unquote forward references once on 3.14.

## Pre-Commit Self-Check

Before saying "done" on a Python change, verify:

- [ ] The type checker (pyright / mypy / ty) passes with zero errors in strict mode.
- [ ] `ruff check` and `ruff format --check` are clean.
- [ ] Every function, method, and public attribute is annotated with modern syntax — no legacy `typing.List` /
      `Optional` / `Union`, no `Any` smuggled in.
- [ ] Data objects are frozen dataclasses / `NamedTuple` unless mutation is genuinely required and explicit; no bare
      dicts standing in for structs.
- [ ] No mutable default arguments; no `assert` used for runtime validation.
- [ ] Exceptions are specific (a custom hierarchy off the right built-in), caught narrowly; no bare `except`.
- [ ] Resources use `with`; paths use `pathlib`; interpolation uses f-strings (t-strings where the output is escaped).
- [ ] Interfaces are `Protocol`s; dependencies are injected, not constructed inline or pulled from globals.
- [ ] Closed value sets are enums; `match` / `case` is used over long `isinstance` chains where it reads better.
- [ ] Tests exist and pass (`pytest`), including error paths via `pytest.raises`; `pyproject.toml` / `uv.lock` are
      updated for any new dependency.
