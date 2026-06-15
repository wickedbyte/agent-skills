# Exceptions and Control Flow

Name exceptions after the problem, layer a per-package marker interface over the correct SPL base, pass domain values
(not formatted strings), keep exceptions out of expected flow, prefer `match` over `switch`, and follow the
`get`/`find`/`has`/`is`/`can` method vocabulary.

## Table of contents

- [Name the problem, not the category — no `Exception` suffix](#name-the-problem-not-the-category--no-exception-suffix)
- [Per-package marker interface over the SPL base](#per-package-marker-interface-over-the-spl-base)
- [Choosing the SPL base](#choosing-the-spl-base)
- [Constructors take domain values, not formatted strings](#constructors-take-domain-values-not-formatted-strings)
- [Exceptions are not flow control](#exceptions-are-not-flow-control)
- [`match` over `switch`](#match-over-switch)
- [Exhaustiveness and `UnreachableCode`](#exhaustiveness-and-unreachablecode)
- [Guard clauses](#guard-clauses)
- [Method-naming vocabulary](#method-naming-vocabulary)

## Name the problem, not the category — no `Exception` suffix

An exception's class name should, read alone in a stack trace, tell you exactly what went wrong. The base class already
says "this is an exception," so the `Exception` suffix is pure redundancy. Name the _problem_, not the category.

| ❌ Category name + suffix   | ✅ Problem statement |
| --------------------------- | -------------------- |
| `FileException`             | `UnableToReadFile`   |
| `NotFoundException`         | `TombstoneNotFound`  |
| `ValidationException`       | `InvalidTraceDepth`  |
| `LogicException` (your own) | `UnreachableCode`    |

Naming conventions that work:

- **`UnableTo…`** for an external operation that was attempted and failed: `UnableToReadFile`, `UnableToWriteFile`,
  `UnableToCreateDirectory`.
- **Adjective / past participle** for an impossible-looking state: `NotFound`, `NotImplemented`, `NotInstantiable`,
  `SerializationProhibited`.
- **Noun phrase** for a specific invariant violation: `CircularDependency`, `InvalidStringableOffset`,
  `UnreachableCode`.

## Per-package marker interface over the SPL base

Each package defines a single marker interface extending `\Throwable`. Every concrete exception in the package both
**extends the correct SPL base** _and_ **implements the marker**. This lets a caller catch "anything from this package"
with one clause without forcing all exceptions under a shared abstract class (which would conflict with extending the
right SPL base).

```php
interface BillingException extends \Throwable {}

final class InvoiceNotFound extends \RuntimeException implements BillingException {}
final class InvalidLineItem extends \InvalidArgumentException implements BillingException {}
final class InvoiceAlreadyPaid extends \LogicException implements BillingException {}
```

```php
try {
    $billing->charge($invoice);
} catch (InvoiceAlreadyPaid $e) {   // catch one specific problem
    // ...
} catch (BillingException $e) {     // or catch anything from the package
    // ...
}
```

The marker layers _on top of_ the SPL hierarchy — it never replaces it. For packages where the logic/runtime split
matters to callers (crypto, storage adapters), add categorical sub-interfaces (`BillingLogicException`,
`BillingRuntimeException`) so a caller can rethrow only the environmental failures and let programmer errors propagate.

When an exception represents a PSR concept, implement that PSR interface too (`class NotFound extends \LogicException
implements NotFoundExceptionInterface {}`) so framework code can catch the PSR interface.

## Choosing the SPL base

Extend the _most specific correct_ SPL base — never `\Exception` directly, and never `\RuntimeException` reflexively.

| SPL base                                                               | Use for                                                                                                                                               |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `\LogicException`                                                      | A programmer error or violated precondition — should be impossible in correct code (invalid state, unreachable branch, calling a method out of order) |
| `\InvalidArgumentException`                                            | A specific bad argument to a method (a subtype of `LogicException`)                                                                                   |
| `\RuntimeException`                                                    | A failure only detectable at runtime — I/O, network, "not found" against live data                                                                    |
| `\UnexpectedValueException`                                            | Unexpected _output_ from a dependency (a subtype of `RuntimeException`)                                                                               |
| `\OutOfBoundsException` / `\OverflowException` / `\UnderflowException` | Index missing / collection full / collection empty when a value is required                                                                           |

The mental test: _could correct code, given valid inputs and a healthy environment, ever hit this?_ If no, it is a
`LogicException`. If it depends on the state of the world at runtime, it is a `RuntimeException`.

## Constructors take domain values, not formatted strings

An exception constructor should accept the **domain value(s)** that caused the failure and build the message itself.
This
keeps the message format in one place, makes the throw site clean, and lets tests assert on the _type_ (and on the
preserved domain value) rather than a brittle message string.

```php
// ❌ Message assembled at the throw site — the format scatters across the codebase
throw new \InvalidArgumentException("Trace depth must be between 1 and 100, got {$depth}");

// ✅ Pass the domain value; the message lives in one place; the value is recoverable
throw new InvalidTraceDepth($depth);

final class InvalidTraceDepth extends \InvalidArgumentException implements BillingException
{
    public function __construct(public readonly int $depth)
    {
        parent::__construct(\sprintf('Trace depth must be between 1 and 100, got %d', $depth));
    }
}
```

A static named constructor (`UnableToReadFile::atPath($path, $previous)`) is the right tool when one exception is always
built from the same context and you want to centralize the message and the `previous`/`cause` wiring.

## Exceptions are not flow control

Exceptions are for _unexpected_ conditions — broken invariants, unreachable dependencies, programmer errors. An
**expected** absence or alternative outcome is a return value, not a throw. Throwing is also genuinely expensive (stack
capture), so using it for the common path is both a design smell and a performance one.

```php
// ❌ "Not found" is an expected outcome — catching it is exceptions-as-flow-control
try {
    $user = $repository->find($id);
} catch (UserNotFound $e) {
    return $this->createGuestSession();
}

// ✅ Expected absence is a return value
$user = $repository->find($id); // User|null
if ($user === null) {
    return $this->createGuestSession();
}
```

The decision:

| Situation                             | Pattern                                                        |
| ------------------------------------- | -------------------------------------------------------------- |
| Programmer error / violated invariant | Throw (`LogicException` subtype)                               |
| Environmental failure (I/O, network)  | Throw (`RuntimeException` subtype), with `previous`            |
| Expected "not found"                  | Return `T\|null` from a `find*()` method                       |
| Expected success-or-typed-failure     | Union return (`ParsedValue\|ParseFailure`) or a `Result<T, E>` |
| Caller may want to throw, or not      | Return a `\Throwable` subclass the caller can choose to throw  |

`@throws` is rarely needed — PHPStan tracks throw types through call chains. Annotate only an interface method where the
thrown type is part of the published contract (e.g. PSR-18's `ClientExceptionInterface`); if callers _must_ catch a
specific type, that often means the value should have been a union return instead.

## `match` over `switch`

`match` is an expression, compares with strict `===` (no type juggling), has no fall-through, and returns a value
directly. It replaces `switch` in essentially all dispatch.

```php
// ✅ match: strict, expression, no break/fall-through
$cssClass = match ($status) {
    PostStatus::Draft     => 'draft',
    PostStatus::Published => 'published',
    PostStatus::Archived  => 'archived',
};
```

Choose the form by _comparison semantics_, not branch count:

- **`match ($value)`** for identity dispatch (enums, exact values).
- **`match (true)`** for three or more range/boolean conditions — cleaner than an `if`/`elseif` ladder.
- **Ternary** only for a single two-branch _equality_ check (`$n === 1 ? 'item' : 'items'`). Never nest ternaries.

```php
return match (true) {
    $score >= 90 => Grade::A,
    $score >= 80 => Grade::B,
    $score >= 70 => Grade::C,
    default      => Grade::F,
};
```

## Exhaustiveness and `UnreachableCode`

**Omit `default`** when PHPStan can prove the `match` is exhaustive over a backed enum — every case listed, nothing
else. PHP throws `\UnhandledMatchError` at runtime if an impossible value slips through, which is correct, and adding a
new enum case later becomes a _static analysis error_ at this `match`, forcing you to handle it.

```php
// ✅ No default — exhaustive over the enum; a new case breaks this at analysis time
return match ($status) {
    PostStatus::Draft     => 'draft',
    PostStatus::Published => 'published',
    PostStatus::Archived  => 'archived',
};
```

**Add a throwing `default`** when the matched type is _open_ (a `string`, an `int`, a partially-handled enum) so the
branch is genuinely reachable. Throw a **named domain exception**:

```php
return match ($status) {
    PostStatus::Draft     => 'draft',
    PostStatus::Published => 'published',
    default               => throw new UnexpectedPostStatus($status),
};
```

When a branch is _logically impossible_ but PHPStan cannot prove it (or you want a defensive net that has caught a bug
before), call a `never`-returning helper. The `never` return type tells PHPStan the path terminates, which lets it
narrow
the surrounding type correctly, and it throws loudly if ever reached.

```php
final class UnreachableCode extends \LogicException
{
    public static function reached(mixed $value = null): never
    {
        throw new self('Reached supposedly unreachable code: ' . \var_export($value, true));
    }
}

$label = match ($status) {
    PostStatus::Draft     => 'Draft',
    PostStatus::Published => 'Published',
    PostStatus::Archived  => 'Archived',
    default               => UnreachableCode::reached($status), // never → PHPStan narrows $label to string
};
```

| Situation                                      | Use                                |
| ---------------------------------------------- | ---------------------------------- |
| Logically impossible, PHPStan needs convincing | `UnreachableCode::reached($value)` |
| Possible at runtime (open type, new enum case) | Named domain exception             |

## Guard clauses

Validate at the top of a method and bail early, so the body runs on known-good state. PHP 8.0+ made `throw` an
expression, so a single simple precondition reads well as a short-circuit; compound conditions read better as an `if`.

```php
// ✅ Single simple precondition — short-circuit throw
$quantity > 0 || throw new InvalidQuantity($quantity);

// ✅ Compound condition — if block
if ($start > $end || $end > $this->length()) {
    throw new InvalidRange($start, $end);
}
```

Iterate with `foreach` over an `iterable`, never a `while`/index loop, and never call `count()` in a loop condition —
`foreach` works on generators and lazy collections and removes the question entirely.

## Method-naming vocabulary

A method name is a contract: it tells the caller about nullability, failure, and cost without reading the body. Keep it
consistent across the codebase.

| Prefix / form                        | Contract                                                       |
| ------------------------------------ | -------------------------------------------------------------- |
| `get*`                               | Returns the value **or throws** — the caller asserts it exists |
| `find*`                              | Searches; returns `T\|null` — the caller must handle absence   |
| `has*` / `is*` / `can*` / `should*`  | Returns `bool` (presence / state / capability / policy)        |
| plain noun (`message()`, `caller()`) | A trivial accessor — **no `get` prefix**                       |
| `with*`                              | Returns a new immutable instance with a changed value          |
| `set*` / `add*` / `remove*`          | Mutating state changes (entities/services only)                |

```php
public function message(): string { return $this->message; } // ✅ accessor — no get
public function getMessage(): string { return $this->message; } // ❌ get reserved for retrieval that may throw
```

The repository "contract triangle" makes the distinction concrete — `has()` tests cheaply, `get()` throws on absence,
`find()` returns null — and the caller picks the one matching their certainty:

```php
interface UserRepository
{
    public function has(UserId $id): bool;        // O(1), no throw
    public function get(UserId $id): User;        // throws NotFound
    public function find(UserId $id): User|null;  // null if absent
}
```

A `get*` method must never return `null`, and a `find*` method must never throw merely because the value is absent —
either breaks the contract the name advertises. At the HTTP boundary, turn these typed exceptions into RFC 7807
`application/problem+json` responses; never leak internal class names or stack traces to clients.
