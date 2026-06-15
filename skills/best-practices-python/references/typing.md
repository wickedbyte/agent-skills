# Typing

Built-in generics, `X | None`, PEP 695 generics, the structural toolkit (`Protocol` / `TypedDict` / `Literal` /
`NewType` / `Self` / `Final` / `assert_never`), `@overload`, deferred-annotation semantics, and the discipline of
validating untrusted input at the boundary.

## Modern syntax — built-ins, not `typing` aliases

The legacy `typing` collection aliases and `Optional` / `Union` are dead weight on 3.14. Use the built-ins and the `|`
operator everywhere.

| Legacy                                                       | Modern                                                       |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| `List[int]`, `Dict[str, int]`, `Tuple[int, ...]`, `Set[str]` | `list[int]`, `dict[str, int]`, `tuple[int, ...]`, `set[str]` |
| `Optional[str]`                                              | `str \| None`                                                |
| `Union[int, str]`                                            | `int \| str`                                                 |
| `Callable[[int], str]`                                       | `collections.abc.Callable[[int], str]`                       |
| `Iterable[T]`, `Sequence[T]`, `Mapping[K, V]`                | from `collections.abc`, not `typing`                         |

```python
# ❌ Legacy imports the checker no longer needs
from typing import List, Dict, Optional, Union

def tags(post: Dict[str, object]) -> Optional[List[str]]: ...

# ✅ Built-in generics + union operator
def tags(post: dict[str, object]) -> list[str] | None: ...
```

WHY: the built-in generics have been subscriptable since 3.9 and the `|` operator since 3.10. Keeping the `typing`
imports adds an import, an indirection, and a second spelling for one concept. Ruff's `UP` rules rewrite them
mechanically — there is no reason to author them by hand.

## PEP 695 generics and the `type` statement

Declare type parameters inline. Never reach for `TypeVar` / `Generic[T]` / `TypeAlias`.

```python
# ❌ The pre-695 dance
from typing import TypeVar, Generic, TypeAlias
T = TypeVar("T")
class Box(Generic[T]): ...
Json: TypeAlias = "str | int | float | bool | None | list[Json] | dict[str, Json]"

# ✅ Inline parameters and the `type` statement
def first[T](xs: list[T]) -> T | None:
    return xs[0] if xs else None

class Box[T]:
    def __init__(self, value: T) -> None:
        self.value = value

type Json = str | int | float | bool | None | list["Json"] | dict[str, "Json"]
```

Bounds and constraints also go inline: `def clamp[T: (int, float)](lo: T, hi: T, x: T) -> T:` for constraints,
`def largest[T: Comparable](xs: list[T]) -> T:` for an upper bound.

WHY the quotes on `Json`: a `type` statement's value is _lazily_ evaluated, but the alias name is not yet bound to a
symbol while its own right-hand side is being parsed. A self-referential alias therefore still needs the name quoted
(`list["Json"]`) — this is the one place quoting survives on 3.14. Regular forward references in function and class
annotations do **not** need quotes (see deferred annotations below).

## The structural toolkit

| Tool                | Use for                                                                                      |
| ------------------- | -------------------------------------------------------------------------------------------- |
| `Protocol`          | A structural interface — any class with the right shape conforms. See `protocols-and-di.md`. |
| `TypedDict`         | A dict with a fixed, known set of string keys (e.g. a JSON payload shape you do not own).    |
| `Literal["a", "b"]` | A value restricted to specific constants when an enum is overkill.                           |
| `NewType`           | A distinct type over a primitive (`UserId = NewType("UserId", int)`) with zero runtime cost. |
| `Self`              | A method that returns its own (possibly subclass) type.                                      |
| `Final`             | A name that must not be reassigned or overridden.                                            |
| `assert_never`      | Exhaustiveness checking at the end of a `match` or `if` chain.                               |

```python
from typing import Final, Literal, NewType, Self, TypedDict, assert_never

UserId = NewType("UserId", int)          # distinct from a bare int to the checker

MAX_RETRIES: Final = 3                    # reassigning this is a type error

class Movement(TypedDict):
    dx: int
    dy: int

Direction = Literal["north", "south", "east", "west"]

class QueryBuilder:
    def where(self, clause: str) -> Self:  # subclasses return their own type
        self._clauses.append(clause)
        return self

def step(d: Direction) -> Movement:
    match d:
        case "north": return {"dx": 0, "dy": 1}
        case "south": return {"dx": 0, "dy": -1}
        case "east":  return {"dx": 1, "dy": 0}
        case "west":  return {"dx": -1, "dy": 0}
        case _:
            assert_never(d)                # checker errors if a case is missed
```

WHY `NewType`: passing a raw `int` where a `UserId` is expected is exactly the bug a type system should catch. `NewType`
gives you a nominal distinction the checker enforces, with no wrapper object at runtime.

WHY `assert_never`: when you add a fifth direction, the checker flags the `step` function as non-exhaustive instead of
silently falling through. It turns "add a variant" into a compile-time checklist.

## `@overload` for shape-dependent return types

When the return type depends on the _value_ or _type_ of an argument, declare overloads. The implementation signature
carries the union and is not itself callable as a typed variant.

```python
from typing import overload

@overload
def parse(raw: str) -> str: ...
@overload
def parse(raw: bytes) -> bytes: ...
def parse(raw: str | bytes) -> str | bytes:
    return raw.strip()
```

Do not overload merely to document — overload only when a single signature would lose precision a caller depends on.

## Deferred annotations (PEP 649/749)

On 3.14 annotations are evaluated **lazily**, only when something asks for them. Three consequences:

```python
# ✅ Forward reference with no quotes and no __future__ import
class TreeNode:
    def __init__(self, parent: TreeNode | None = None) -> None:
        self.parent = parent
        self.children: list[TreeNode] = []
```

1. Forward references just work — no `"TreeNode"` quoting, no `from __future__ import annotations`. Drop both when
   modernizing.
2. Import-time cost is gone: an annotation referencing an expensive-to-construct type is never evaluated unless someone
   introspects it.
3. **Introspect through `annotationlib`, never `__annotations__` or `eval()`.** Raw `__annotations__` access can now
   trigger evaluation that fails or has surprising semantics.

```python
import annotationlib
from annotationlib import Format

# ✅ Resolved real types (DI containers, serializers, validators)
hints = annotationlib.get_annotations(TreeNode.__init__, format=Format.VALUE)

# ✅ Strings, without forcing forward refs to resolve (doc tools, schema dumps)
as_text = annotationlib.get_annotations(TreeNode.__init__, format=Format.STRING)
```

WHY: a decorator or DI container that reads `func.__annotations__` directly may now evaluate a forward reference before
the referenced symbol exists, raising `NameError` at the worst time. `get_annotations` with an explicit `Format` is the
sanctioned, predictable path: `VALUE` for resolved types, `FORWARDREF` to tolerate unresolved names, `STRING` for the
source text.

## Avoid `Any`; validate at the boundary

`Any` switches the checker off for every value it touches and every value derived from it — it is contagious. Two
disciplines keep it out.

**Use `object` + narrowing, or a `Protocol`, instead of `Any`.** `object` accepts anything but forces you to narrow
before use, so the checker stays on. A `Protocol` is better still when you only need a capability.

```python
# ❌ Any disables checking downstream
def describe(value: Any) -> str:
    return value.upper()          # no error even if value is an int

# ✅ object forces a narrowing the checker verifies
def describe(value: object) -> str:
    if isinstance(value, str):
        return value.upper()
    return repr(value)
```

**Parse untrusted input into a typed object at the edge; never pass `Any` inward.** External data (HTTP bodies, env
vars, file contents, query results) arrives untyped. Validate it once, at the boundary, into a frozen dataclass or a
`TypedDict`, and let the rest of the program work in fully typed terms.

```python
import json
from dataclasses import dataclass

@dataclass(frozen=True, slots=True)
class CreateUser:
    name: str
    email: str

def parse_create_user(body: str) -> CreateUser:
    raw: object = json.loads(body)
    if not isinstance(raw, dict):
        raise ValueError("expected a JSON object")
    name, email = raw.get("name"), raw.get("email")
    if not isinstance(name, str) or not isinstance(email, str):
        raise ValueError("name and email must be strings")
    return CreateUser(name=name, email=email)   # everything downstream is typed
```

WHY: the boundary is the only place the program meets values it cannot trust. Validate there, convert to a domain type,
and every function inside the boundary gets to assume well-formed, fully-typed input. A `dict[str, Any]` threaded
through the call graph is an unchecked contract that fails far from where it was violated. For non-trivial schemas reach
for Pydantic or `attrs` (see `data-modeling.md`) rather than hand-rolling validators.
