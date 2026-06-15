# Data Modeling

Value objects, the record-type decision, frozen-dataclass mechanics (`slots`, `__post_init__`, the `replace()` wither),
`field(default_factory=...)`, the full enum family, and `functools.cached_property`.

## Pick the record type deliberately

| You need…                                                        | Use                                                        | Why                                                                                   |
| ---------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| An immutable domain value with named fields, equality, hashing   | `@dataclass(frozen=True, slots=True)`                      | The default. Validation in `__post_init__`, methods, properties, low memory.          |
| A lightweight positional record / hashable key, tuple-unpackable | `NamedTuple`                                               | Indexable and unpackable like a tuple; minimal overhead; immutable.                   |
| Mutable state behind explicit methods                            | Plain class with `__slots__` (or `@dataclass(slots=True)`) | When mutation is genuinely the point — caches, builders, registries.                  |
| Runtime parsing / coercion / rich validation of untrusted input  | `attrs` or Pydantic                                        | Converters, validators, and (Pydantic) JSON (de)serialization beyond `__post_init__`. |

```python
from dataclasses import dataclass
from typing import NamedTuple

@dataclass(frozen=True, slots=True)
class Money:                 # domain value with behavior
    amount_cents: int
    currency: str

class Point(NamedTuple):     # positional key, unpacks: x, y = p
    x: int
    y: int
```

WHY frozen + slots is the default: `frozen=True` buys immutability, hashability, and value equality; `slots=True` drops
the per-instance `__dict__` for a real memory and attribute-speed win. One decorator, three guarantees. Reach past it
only when a row in the table above describes your case more precisely.

WHY not `NamedTuple` for everything: a `NamedTuple` _is_ a tuple, so it compares equal to and unpacks against other
tuples, which leaks abstraction (`Point(1, 2) == (1, 2)` is `True`) and invites positional bugs. Use it for genuine
positional records and keys, not as a general value-object substitute.

## Frozen dataclass mechanics

### `__slots__` via the decorator

Get slots from `@dataclass(slots=True)` — do not hand-write a separate `__slots__` attribute. The decorator generates
the correct slots for the declared fields and rebuilds the class so it composes with `frozen` and inheritance.

```python
# ❌ Hand-rolled, easy to desync from the fields, fights the decorator
@dataclass(frozen=True)
class Money:
    __slots__ = ("amount_cents", "currency")
    amount_cents: int
    currency: str

# ✅ Let the decorator generate slots
@dataclass(frozen=True, slots=True)
class Money:
    amount_cents: int
    currency: str
```

### Validation and normalization in `__post_init__`

`__post_init__` runs after the generated `__init__`. Validate there. To _normalize_ a field on a frozen instance you
must go through `object.__setattr__`, since normal assignment is blocked.

```python
@dataclass(frozen=True, slots=True)
class EmailAddress:
    value: str

    def __post_init__(self) -> None:
        if "@" not in self.value:
            raise ValueError(f"Invalid email: {self.value}")
        # normalize on a frozen instance — assignment would raise FrozenInstanceError
        object.__setattr__(self, "value", self.value.strip().lower())

    @property
    def domain(self) -> str:
        return self.value.split("@", 1)[1]
```

WHY `object.__setattr__`: `frozen=True` overrides `__setattr__` to raise, which is what you want everywhere except the
one moment during construction when you are canonicalizing input. Bypassing it deliberately, by name, keeps the escape
hatch visible and confined to `__post_init__`.

### Evolve with `dataclasses.replace()` — the wither

Never mutate. Produce a changed copy.

```python
from dataclasses import replace

published = replace(post, status=PostStatus.PUBLISHED, published_at=now)
```

`replace()` runs `__init__` (and therefore `__post_init__`) on the new instance, so validation re-runs on the result.
Prefer it over hand-written `with_*` methods unless a method adds genuine domain meaning.

### `field(default_factory=...)` for mutable or computed defaults

A bare mutable default (`tags: list[str] = []`) is the same shared-instance trap as a mutable default argument — the
dataclass forbids it and raises at class-definition time. Use `default_factory`.

```python
from dataclasses import dataclass, field

@dataclass(frozen=True, slots=True)
class Document:
    title: str
    tags: tuple[str, ...] = ()                      # immutable default: a literal is fine
    history: list[str] = field(default_factory=list)  # fresh list per instance
    created_at: datetime = field(default_factory=lambda: datetime.now(tz=UTC))
```

Prefer an immutable default (`()`, `frozenset()`) on a frozen value object; use `default_factory` when the field is
genuinely a fresh mutable container or a computed value.

## The enum family

| Subclass           | Use for                                           | Note                                                      |
| ------------------ | ------------------------------------------------- | --------------------------------------------------------- |
| `StrEnum`          | Values that cross an API or DB boundary           | Members compare equal to plain `str`.                     |
| `IntEnum`          | Wire integers, status codes                       | Members compare equal to plain `int`.                     |
| `Enum`             | A closed set with no primitive identity to expose | The safe default when you do _not_ want str/int equality. |
| `Flag` / `IntFlag` | Combinable bit options                            | Supports `\|`, `&`, membership.                           |

Use `auto()` for opaque values, and put behavior on the enum as methods and properties.

```python
from enum import StrEnum, IntEnum, Flag, auto, member, nonmember

class PostStatus(StrEnum):
    DRAFT = auto()       # "draft"  — auto() lowercases the member name for StrEnum
    PUBLISHED = auto()   # "published"
    ARCHIVED = auto()

    def is_visible(self) -> bool:
        return self is PostStatus.PUBLISHED

    @property
    def label(self) -> str:
        return self.name.title()

class HttpStatus(IntEnum):
    OK = 200
    NOT_FOUND = 404

class Permission(Flag):
    READ = auto()
    WRITE = auto()
    ADMIN = READ | WRITE
```

WHY `StrEnum` + `auto()` + methods, and NOT a class-level `_labels = {}` dict: storing per-member metadata in a mutable
dict inside the enum body is fragile — it relies on populating the dict _after_ class creation, breaks under
introspection, and divorces the data from the member. Derive display text from `self.name` (`self.name.title()`) or, if
labels are arbitrary, attach them as a second value. Behavior belongs in methods on the enum, where it travels with the
member and the checker can see it.

### `@member` / `@nonmember`

By default every non-callable, non-dunder name in an enum body becomes a member. Use the decorators to override:
`@nonmember` keeps a value as a plain class attribute (not an enum member); `@member` forces something that would
otherwise be skipped (e.g. a callable) to _become_ a member.

```python
class Color(Enum):
    RED = auto()
    GREEN = auto()

    DEFAULT = nonmember(RED)   # a convenience alias, NOT a third member

    @member
    def CUSTOM(value): ...     # a callable promoted to a real member
```

WHY: the default "everything is a member" rule surprises people who add a helper constant or table to the enum body.
`@nonmember` is the explicit, intention-revealing way to keep auxiliary data off the member roster.

## `functools.cached_property`

For an expensive, _deterministic_ value derived from the object's fields, cache it with `cached_property`. It computes
once on first access and stores the result.

```python
from functools import cached_property

class Report:
    def __init__(self, rows: list[Row]) -> None:
        self.rows = rows

    @cached_property
    def totals(self) -> Totals:
        return compute_totals(self.rows)   # runs once, then cached
```

Caveats: it writes to the instance `__dict__`, so it does **not** work on a `slots=True` class without a `__dict__`,
and it is wrong on a `frozen=True` value object whose identity is its fields (a cache mutation contradicts "frozen").
Use it on mutable service-style objects with stable inputs. For a pure function, prefer `functools.lru_cache` /
`functools.cache` on the function instead.
