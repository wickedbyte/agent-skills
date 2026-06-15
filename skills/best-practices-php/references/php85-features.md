# PHP 8.5 and 8.4 Features

The concrete syntax for features that postdate most training data — pipes, clone-with, `#[\NoDiscard]`, property hooks,
asymmetric visibility — plus the version-constraint policy that lets you use them unconditionally.

Every example here is valid PHP 8.5. Use these features where they make code _more_ analyzable or obvious — never as
decoration.

## Table of contents

- [PHP 8.5](#php-85)
    - [Pipe operator `|>`](#pipe-operator-)
    - [Clone-with — the array form](#clone-with--the-array-form)
    - [`#[\NoDiscard]`](#nodiscard)
    - [`array_first()` / `array_last()`](#array_first--array_last)
    - [`#[\Override]` on properties](#override-on-properties)
    - [Closures in constant and attribute expressions](#closures-in-constant-and-attribute-expressions)
- [PHP 8.4](#php-84)
    - [Property hooks](#property-hooks)
    - [Asymmetric visibility](#asymmetric-visibility)
    - [`new` without parentheses](#new-without-parentheses)
    - [Lazy objects](#lazy-objects)
- [Version-constraint policy](#version-constraint-policy)

## PHP 8.5

### Pipe operator `|>`

The pipe operator threads a **single value** left-to-right through a series of callables. The left-hand side is any
expression; the right-hand side must be a **callable that takes exactly one argument** and whose result becomes the next
left-hand side. It pairs naturally with first-class callable syntax (`trim(...)`), which is how you turn a function or
method into the one-arg callable the operator wants.

```php
// ✅ Reads top-to-bottom; each stage is an analyzable one-arg callable
$slug = $title
    |> trim(...)
    |> strtolower(...)
    |> static fn (string $s): string => \preg_replace('/[^a-z0-9]+/', '-', $s);

// Equivalent to, but clearer than, the nested form:
$slug = \preg_replace('/[^a-z0-9]+/', '-', strtolower(trim($title)));
```

Each RHS receives one argument. To pipe into a function that needs more, wrap it in an arrow function that closes over
the extras (`|> static fn (string $s): string => \str_replace(' ', '-', $s)`). Use `|>` for genuine single-value
transformation pipelines; it replaces `call_user_func` and string callables, which PHPStan cannot follow. It does not
replace `array_map`/`foreach` over a collection.

### Clone-with — the array form

PHP 8.5's clone-with expression produces a modified copy of an object (the idiomatic wither for a `readonly` value
object) by passing an **associative array of property overrides** as the second argument to `clone()`.

```php
final readonly class Color
{
    public function __construct(
        public int $red,
        public int $green,
        public int $blue,
        public int $alpha = 255,
    ) {}

    public function withAlpha(int $alpha): self
    {
        return clone($this, ['alpha' => $alpha]);
    }
}
```

> **Correct syntax.** The shipped form is `clone($object, ['prop' => $value])` — an associative array. An earlier RFC
> draft proposed a brace block, `clone($obj){ alpha: 255 }`; that syntax **was never released** and is invalid PHP. If
> you see or are tempted to write the brace-block form, it is wrong — use the array form.

```php
// ❌ Brace-block draft — never shipped, is a parse error
$faded = clone($color){ alpha: 128 };

// ✅ Shipped 8.5 syntax
$faded = clone($color, ['alpha' => 128]);
```

The array's keys are property names and its values are the overrides; properties not named keep their current value. It
respects `readonly` (this is the sanctioned way to "change" a readonly property) and runs the class's `__clone()` if
defined.

### `#[\NoDiscard]`

`#[\NoDiscard]` marks a function or method whose return value **must be consumed**. Calling it and ignoring the result
raises a warning — the right tool for builders, withers, and any pure function whose entire point is the value it
returns (a discarded result almost always signals a bug).

```php
final readonly class QueryBuilder
{
    #[\NoDiscard('the returned builder is immutable; the original is unchanged')]
    public function where(string $column, string $value): self
    {
        return clone($this, ['filters' => [...$this->filters, $column => $value]]);
    }
}

$qb->where('status', 'active'); // ⚠️ warning: return value of where() is discarded
$qb = $qb->where('status', 'active'); // ✅ consumed
```

When you genuinely intend to discard the value (a side-effecting call that also returns something), make the intent
explicit with the `(void)` cast:

```php
(void) $logger->log($message); // intentional discard, no warning
```

### `array_first()` / `array_last()`

`array_first()` and `array_last()` return the first and last _value_ of an array (or `null` if empty) without mutating
it and without the `reset()`/`end()` internal-pointer dance or the `array_key_first()` indirection.

```php
$first = array_first($items); // first value, or null
$last  = array_last($items);  // last value, or null

// Replaces:
$first = $items === [] ? null : $items[\array_key_first($items)];
$last  = $items === [] ? null : $items[\array_key_last($items)];
```

They return `null` on an empty array, so on a list whose elements may themselves be `null` you cannot distinguish
"empty" from "first element is null" by the result alone — guard with `$items === []` first if that matters.

### `#[\Override]` on properties

`#[\Override]` has applied to **methods since 8.3** (it makes PHPStan/the engine verify the member actually overrides a
parent — catching a rename that silently turns an override into a new method). PHP 8.5 extends it to **properties**,
including hooked and promoted ones, so a child property that is meant to override a parent's is checked the same way.

```php
abstract class Shape
{
    public float $area { get => 0.0; }
}

final class Square extends Shape
{
    public function __construct(private float $side) {}

    #[\Override]
    public float $area { get => $this->side ** 2; } // verified to override Shape::$area
}
```

Use `#[\Override]` whenever you override a method or property; it costs nothing and catches signature drift when the
parent changes.

### Closures in constant and attribute expressions

PHP 8.5 allows closures (including arrow functions) inside constant expressions — class constants, property defaults,
and
**attribute arguments** — where previously only literals and a few operators were permitted. This lets an attribute
carry a small inline transform or predicate as metadata.

```php
#[\Attribute(\Attribute::TARGET_PROPERTY)]
final readonly class Normalizer
{
    /** @param callable(string): string $fn */
    public function __construct(public mixed $fn) {}
}

final class ImportRow
{
    #[Normalizer(static fn (string $v): string => \trim($v))]
    public string $name = '';
}
```

The closure is still resolved as metadata (resolve once, cache) — this does not license putting control flow into
attributes.

## PHP 8.4

### Property hooks

Property hooks attach `get` and/or `set` logic to a property, so a _computed_ value reads as a property instead of a
method, and a `set` can normalize on assignment — without a private backing field and a pair of accessors.

```php
final class Person
{
    public string $fullName {
        get => "{$this->first} {$this->last}";
    }

    public function __construct(
        public string $first,
        public string $last,
    ) {}
}

$p = new Person('Ada', 'Lovelace');
$p->fullName; // 'Ada Lovelace' — no method call
```

A `set` hook can validate/normalize the incoming value before it is stored:

```php
final class Account
{
    public string $email {
        set (string $value) => $this->email = \strtolower(\trim($value));
    }
}
```

For _immutable_ value objects, prefer a `get`-only hook for derived data; do not use a `set` hook to fake mutability on
a
`readonly` type.

### Asymmetric visibility

A property can have a wider read visibility than write visibility. `public private(set)` means "anyone may read it, only
this class may write it" — the canonical shape for an **entity** property whose value changes through domain methods but
must not be assigned from outside. The set-visibility must be **equal to or narrower than** the get-visibility, and the
property must be **typed**.

```php
// ✅ Entity: id is public to read, settable only within the class
final class Order
{
    public function __construct(
        public private(set) OrderId $id,
        public private(set) OrderStatus $status,
    ) {}

    public function ship(): void
    {
        $this->status->isTerminal() && throw new InvoiceAlreadyPaid($this->id);
        $this->status = OrderStatus::Shipped; // allowed: write is private
    }
}

$order->status;              // ✅ readable
$order->status = $whatever;  // ❌ Error: write access is private(set)
```

`protected(set)` is the analogous "subclasses may write" form. Asymmetric visibility is for _entities_ (mutable
identity, controlled writes); a value object should be `readonly` instead, where nothing may write after construction.

### `new` without parentheses

PHP 8.4 lets you call a method or access a property directly on a `new` expression without wrapping it in parentheses.

```php
// ✅ 8.4+
$result = new Service()->handle($command);
$name   = new Formatter()->format($value);

// Old form (still valid)
$result = (new Service())->handle($command);
```

Use it for the common throwaway-instance case; it removes a layer of parentheses with no loss of clarity.

### Lazy objects

PHP 8.4 adds first-class lazy objects via the Reflection API (`newLazyGhost()` / `newLazyProxy()`): an instance whose
initializer runs only on first access. This is **infrastructure machinery** — ORMs (Doctrine proxies for unfetched
relations) and DI containers (deferred service construction) use it so you do not have to hand-roll lazy-loading. You
will almost never write `newLazyGhost()` in domain code; recognize it when a framework returns a lazy instance, and let
the framework own it.

```php
$reflector = new \ReflectionClass(HeavyReport::class);
$report = $reflector->newLazyGhost(static function (HeavyReport $r): void {
    $r->__construct(/* expensive initialization deferred until first use */);
});
// $report is a HeavyReport; the initializer fires on first property/method access
```

## Version-constraint policy

Use the features above **unconditionally** — do not guard them. That requires raising the floor honestly rather than
hedging.

Declare an **explicit version union**, not a caret range:

```json
{
    "require": {
        "php": "8.4.* || 8.5.*"
    }
}
```

`^8.5` claims compatibility with `8.6`, `8.7`, and every future minor that does not yet exist and has never been tested
— a dishonest promise that has broken real libraries. An explicit union states exactly what you have tested; you update
it once a year as PHP releases and EOLs versions. A library that exists specifically to leverage the latest features may
narrow to `"8.5.*"` and say so in its README.

Two corollaries:

- **No polyfills.** Symfony-polyfill-style shims add a dependency, mask version mismatches, and never get removed. If
  you
  need a feature, raise the floor to the version that introduced it.
- **No `PHP_VERSION_ID` runtime branching.** A `if (\PHP_VERSION_ID >= 80500) { … } else { … }` fork creates two code
  paths that both must be maintained and tested, and the fallback is never deleted. Set the floor and write the feature
  once.

```php
// ❌ Two paths, forever
if (\PHP_VERSION_ID >= 80500) {
    $next = clone($vo, ['alpha' => 128]);
} else {
    $next = $vo->withAlpha(128);
}

// ✅ Floor is 8.5; use the feature directly
$next = clone($vo, ['alpha' => 128]);
```
