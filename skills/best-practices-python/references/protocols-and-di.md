# Protocols and Dependency Injection

Structural typing with `Protocol` over nominal `ABC` inheritance, naming, `@runtime_checkable` and its limits, when ABCs
still win, explicit dependency injection, and Protocol-based test doubles without a mock library.

## Define interfaces as `Protocol`, not `ABC`

A `Protocol` describes the _shape_ a collaborator must have. Any class with matching methods conforms — structurally,
with no inheritance and no registration. An `ABC` demands nominal inheritance: implementers must import and subclass it.

```python
# ❌ ABC forces inheritance and couples every implementation to the abstraction
from abc import ABC, abstractmethod

class RequestContextProviderBase(ABC):
    @abstractmethod
    def context(self) -> RequestContext: ...

class DefaultProvider(RequestContextProviderBase):   # must inherit to qualify
    def context(self) -> RequestContext: ...

# ✅ Protocol — structural; the implementation never names the abstraction
from typing import Protocol

class RequestContextProvider(Protocol):
    def context(self) -> RequestContext: ...

class DefaultProvider:                                # no base class, still conforms
    def context(self) -> RequestContext:
        return RequestContext(method="GET", uri="/")
```

Note the unquoted forward reference `RequestContext` in the protocol method — on 3.14 annotations are deferred, so no
quotes and no `__future__` import are needed even if `RequestContext` is defined later in the module.

WHY structural over nominal: with a `Protocol` the _consumer_ owns the interface and the _producer_ owes it nothing.
You can type a function against `RequestContextProvider` and satisfy it with a class from a third-party library, a test
stub, or a closure-backed object that never heard of your protocol. Nominal `ABC` inheritance inverts that — every
implementer takes a hard dependency on your abstraction, which is the coupling you were trying to break.

## Name protocols as capability nouns — no `Protocol` suffix

A protocol names a capability, so name it for what it _does_ or _provides_, like an interface, not for the fact that it
is a protocol.

| ✅ Good                                      | ❌ Avoid                                  |
| -------------------------------------------- | ----------------------------------------- |
| `RequestContextProvider`                     | `RequestContextProviderProtocol`          |
| `Clock`, `Cache`, `EmailSender`              | `IClock`, `ICache`, `AbstractEmailSender` |
| `SupportsClose` (for tiny one-method shapes) | `CloseableInterface`                      |

WHY: a `Protocol` suffix or `I`/`Abstract` prefix leaks an implementation detail into the type's name. Callers care that
the thing is a `Clock`, not that it happens to be expressed as a protocol. The one idiomatic prefix is `Supports…` for
single-method capability protocols, mirroring the standard library (`SupportsInt`, `SupportsRead`).

## `@runtime_checkable` and its limits

By default a `Protocol` is a _static_ construct — `isinstance(obj, MyProtocol)` raises `TypeError`. Add
`@runtime_checkable` to permit `isinstance`. But understand exactly what that check does.

```python
from typing import Protocol, runtime_checkable

@runtime_checkable
class Closable(Protocol):
    def close(self) -> None: ...

isinstance(some_obj, Closable)   # ✅ True iff some_obj has a `close` attribute
```

`isinstance` against a runtime-checkable protocol checks only **method presence by name** — not signatures, not return
types, not whether `close` even takes the right arguments. A class with an unrelated `close(self, force, timeout)`
passes.

WHY this matters: the runtime check is far weaker than the static check the type checker performs. Lean on the checker
for correctness; reach for `@runtime_checkable` only when you genuinely need a runtime branch (e.g. "if this object is
`Sized`, log its length"), and never treat a passing `isinstance` as proof the object honors the full contract.

## When ABCs still win

`Protocol` is the default for _interfaces_. `ABC` is the right tool when you want to **share implementation** or need
**explicit registration**.

- **Shared implementation:** a base class supplies concrete methods built on a small set of abstract ones (the template
  method pattern). `collections.abc.Mapping` gives you `keys`, `items`, `get`, `__contains__`, `__eq__` for free once
  you implement `__getitem__`, `__len__`, `__iter__`. A protocol cannot hand down behavior.
- **`register()` for virtual subclasses:** when a type you do not control should be recognized as conforming and you
  cannot edit it, `MyABC.register(ThirdPartyType)` makes `isinstance` pass without inheritance.

```python
from collections.abc import Mapping

class ReadOnlyView(Mapping[str, int]):   # implement 3 methods, inherit the rest
    def __init__(self, data: dict[str, int]) -> None:
        self._data = data
    def __getitem__(self, key: str) -> int: return self._data[key]
    def __iter__(self): return iter(self._data)
    def __len__(self) -> int: return len(self._data)
```

Rule of thumb: **want a contract → `Protocol`; want to donate behavior → `ABC`.**

## Inject dependencies explicitly; type them as Protocols

Pass collaborators into constructors and functions. Do not construct them inline, and do not reach for module globals or
singletons. Type each collaborator as a `Protocol` so the call site can supply anything that fits.

```python
from typing import Protocol

class Clock(Protocol):
    def now(self) -> datetime: ...

class Cache(Protocol):
    def get(self, key: str) -> bytes | None: ...
    def set(self, key: str, value: bytes) -> None: ...

# ❌ Hidden dependencies — constructed inline, impossible to substitute
class TokenService:
    def __init__(self) -> None:
        self._clock = SystemClock()
        self._cache = RedisCache(connect())

# ✅ Dependencies injected and typed structurally
class TokenService:
    def __init__(self, clock: Clock, cache: Cache) -> None:
        self._clock = clock
        self._cache = cache

    def issue(self, user_id: str) -> bytes:
        token = mint(user_id, self._clock.now())
        self._cache.set(user_id, token)
        return token
```

WHY: a class that builds its own dependencies hardcodes them — you cannot run it against a fake clock in a test, a
different cache in another environment, or an in-memory stand-in in a benchmark. Injection moves the wiring decision out
to the composition root (your `main`, a factory, a small container), where it belongs, and typing against a `Protocol`
keeps that wiring honest without coupling the service to any concrete implementation.

## Protocol-based test doubles — no mock library

Because conformance is structural, a test double is just a tiny class with the right methods. No `unittest.mock`, no
patching, no magic — a few lines you can read and the type checker verifies against the protocol.

```python
class FrozenClock:                         # conforms to Clock structurally
    def __init__(self, at: datetime) -> None:
        self._at = at
    def now(self) -> datetime:
        return self._at

class InMemoryCache:                       # conforms to Cache structurally
    def __init__(self) -> None:
        self._store: dict[str, bytes] = {}
    def get(self, key: str) -> bytes | None:
        return self._store.get(key)
    def set(self, key: str, value: bytes) -> None:
        self._store[key] = value

def test_issue_caches_token() -> None:
    cache = InMemoryCache()
    service = TokenService(clock=FrozenClock(datetime(2026, 1, 1, tzinfo=UTC)), cache=cache)
    token = service.issue("u1")
    assert cache.get("u1") == token        # assert against real, inspectable state
```

WHY prefer a hand-written double to a `Mock`: a `Mock` accepts _any_ call and returns _another_ `Mock`, so a typo or a
signature drift sails through green — the double silently lies. A small conforming class is checked by the type checker
against the protocol, holds real state you can assert on, and documents exactly what the collaborator is expected to do.
Reach for a mock library only for verifying intricate call sequences on a wide interface; for the common case, a tiny
class is clearer and safer.
