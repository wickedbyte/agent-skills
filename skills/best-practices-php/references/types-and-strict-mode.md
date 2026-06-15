# Types and Strict Mode

`declare(strict_types=1)`, native type declarations on every boundary, deliberate unions, `mixed` only at the edge, and
the docblock generics PHPStan needs to reason about your code.

## `declare(strict_types=1)` on every file

Strict mode turns silent scalar coercion into a visible `TypeError`. Without it, `function f(int $x)` happily accepts
`"3"` and even `"3abc"` (with a warning), which means the type in the signature is a suggestion, not a contract. The
declaration only affects calls _originating in the file that declares it_, so it cannot be set "globally" — it belongs
at the top of **every** `.php` file, before the `namespace`.

```php
<?php

declare(strict_types=1);

namespace App\Billing;
```

A file without it is a hole in your analysis: PHPStan trusts the signatures, but the runtime does not enforce them.

## Type every boundary natively; docblocks carry only what the syntax cannot

Native parameter, return, and property types are the contract. Aim for **~100% native coverage on public APIs** — a
public method with an untyped parameter or a bare `array` return is unfinished. Reserve docblocks for the two things the
type syntax cannot express: array/iterable _shapes_ and _generics_.

```php
// ❌ Bare array tells the caller and PHPStan nothing
public function frames(): array { /* ... */ }

// ✅ Native type + docblock shape
/** @return list<StackFrame> */
public function frames(): array { /* ... */ }
```

A bare `array` on a public method is not acceptable: `array` could be a list, a map, a tuple, or a nested structure, and
the caller has to read the implementation to find out. The docblock removes that ambiguity and PHPStan enforces it at
every call site.

## Union types are deliberate, not accidental

A union (`A|B`) is a precise statement: "this is exactly one of these, decided at runtime." Use it where the domain
genuinely has alternatives (`int|string` for an identifier that may be either, `EmailAddress|null` for honest
absence). Do _not_ let unions accumulate as a substitute for a redesign — a return type of
`User|Admin|Guest|null|false` is a design smell, usually fixable with a value object, an interface, or a `Result` type.

```php
// ✅ Deliberate: a coordinate accepts either form, coerces to one internally
public function from(self|\Stringable|string $value): self { /* ... */ }
```

For factories that return _different concrete types per input_, do not enumerate a union — it goes stale the moment a
new
type is added and forces `instanceof` at every call site. Use `@template` instead (see below).

## `mixed` only at a genuine boundary, then narrow immediately

`mixed` is the absence of a type. It is acceptable in exactly one place: where untyped data _enters_ the program —
`json_decode()` output, a `$_POST` value, a third-party callback's argument. The moment it crosses the boundary, narrow
it. Code downstream of the boundary should never see `mixed`.

```php
// ✅ mixed enters, gets narrowed at once, never propagates inward
public function handle(mixed $payload): OrderPlaced
{
    \is_array($payload) || throw new \InvalidArgumentException('Payload must be an array');

    return OrderPlaced::from($payload); // from() validates and returns a typed object
}
```

If a method signature is stuck on `mixed` or a bare `array` and _cannot_ be narrowed with the annotations below, that is
a signal to redesign the interface — not to suppress the PHPStan finding with `@phpstan-ignore`.

## Docblock generics: the vocabulary PHPStan understands

These annotations cannot be expressed in native PHP syntax, so they live in docblocks. PHPStan at `level: max` enforces
every one of them.

| Annotation              | Meaning                                                                          |
| ----------------------- | -------------------------------------------------------------------------------- |
| `list<T>`               | A sequentially indexed array (`0, 1, 2, …`) of `T` — use for ordered collections |
| `array<K, V>`           | A map with keys of type `K` and values of type `V`                               |
| `non-empty-array<K, V>` | An array guaranteed to have at least one element                                 |
| `iterable<T>`           | Any `Traversable` or `array` yielding `T` — prefer on public params              |
| `class-string<T>`       | A string that is a valid FQCN of type `T`                                        |
| `non-empty-string`      | A string guaranteed not to be `''`                                               |
| `positive-int`          | An integer guaranteed `> 0` (`negative-int`, `non-negative-int` also exist)      |

```php
/**
 * @param non-empty-string $key
 * @param positive-int $ttl
 * @return array<non-empty-string, scalar>
 */
public function load(string $key, int $ttl): array { /* ... */ }
```

### Prefer `iterable<T>` over `array<T>` on interface parameters and returns

`iterable` accepts both `array` and `Traversable`, so an interface typed `iterable<T>` lets implementations return
generators or lazy collections without breaking the contract. Reserve `array`/`list` for cases where the caller needs
random access, `json_encode`, or `array_map` — i.e. where an in-memory array is genuinely required.

```php
// ❌ Locks every implementation into building a full in-memory array
interface StackTraceProvider
{
    /** @return list<StackFrame> */
    public function frames(): array;
}

// ✅ Implementations may yield lazily
interface StackTraceProvider
{
    /** @return iterable<StackFrame> */
    public function frames(): iterable;
}
```

## `@template` for generic methods, interfaces, and factories

When a method's return type depends on its input, `@template` narrows the return at the call site. It is **not optional
**
on a generic method — without it the return type collapses to `object` and every caller needs a cast.

```php
/**
 * @template T of object
 * @param class-string<T> $id
 * @return T
 */
public function get(string $id): object { /* ... */ }

$mailer = $container->get(MailerInterface::class); // PHPStan infers MailerInterface
```

A factory that dispatches on a `class-string<T>` is both more ergonomic and safer than a union return: PHPStan narrows
the result and rejects a class-string that violates the `T of Base` constraint.

```php
/**
 * @template T of HandlerInterface
 * @param class-string<T> $type
 * @return T
 */
public function create(string $type): HandlerInterface
{
    return match ($type) {
        EmailHandler::class => new EmailHandler(),
        SmsHandler::class   => new SmsHandler(),
        default             => throw new UnknownHandlerType($type),
    };
}
```

Declare `@template` on an _interface_ when the interface itself is generic (a typed repository, a typed collection), and
bind it on each implementation with `@implements`:

```php
/**
 * @template T of object
 */
interface Repository
{
    /** @return T|null */
    public function find(string $id): object|null;

    /** @param T $entity */
    public function save(object $entity): void;
}

/**
 * @implements Repository<Tombstone>
 */
final class InMemoryTombstoneRepository implements Repository
{
    /** @return Tombstone|null */
    public function find(string $id): object|null { /* ... */ }

    /** @param Tombstone $entity */
    public function save(object $entity): void { /* ... */ }
}
```

## Generic docblocks repeat on the interface AND every implementation

This is the rule that trips people up. PHPStan treats the docblock generics on a method as part of _that declaration's_
signature — they are **not** inherited silently. An `@return list<T>` on an interface method does not propagate to the
implementing class. If the implementation omits it, PHPStan widens the implementation's return to a bare `array` and you
lose the element type at every call site that holds the concrete type.

```php
interface LineItemSource
{
    /** @return list<LineItem> */
    public function items(): array;
}

// ❌ Annotation dropped — PHPStan sees array, not list<LineItem>, on this class
final class CartLineItemSource implements LineItemSource
{
    public function items(): array { /* ... */ }
}

// ✅ Annotation repeated; the implementation may covariantly narrow it
final class CartLineItemSource implements LineItemSource
{
    /** @return non-empty-list<LineItem> */
    public function items(): array { /* ... */ }
}
```

Implementations may **covariantly narrow** the generic: a method declared `@return list<T>` on the interface may return
`@return non-empty-list<T>` on the implementation, just as a native return type may narrow from `iterable` to `array`.
They may never _widen_ it. The same applies to `@param` (which is contravariant — an implementation may accept a wider
type) and to `@template` bounds. When in doubt, copy the interface's annotation onto the implementation verbatim and
narrow only with intent.

## Typed class constants

Since PHP 8.3, class constants carry an explicit type. Always declare both visibility and type — an untyped or
implicitly-public constant is unfinished. Use the narrowest correct type.

```php
final readonly class StackFrame
{
    public const string TYPE_STATIC   = '::';
    public const string TYPE_OBJECT   = '->';
    public const int    DEFAULT_DEPTH = 10;
}
```

Interface constants are implicitly public, so declare the type but omit the (only-valid) `public` modifier:

```php
interface HasVersion
{
    const string VERSION = '1.0.0';
}
```

## The principle

PHPStan at `level: max` is the contract reader. If the analyzer can prove a fact — this is a `non-empty-list<LineItem>`,
this `class-string<T>` returns `T`, this `match` is exhaustive — then the next maintainer can rely on it without running
the code. Every native type and every docblock generic exists to push one more fact out of the runtime and into the type
system. A `@phpstan-ignore` throws that fact away; fix the type instead, and reserve ignores for a confirmed tool or
stub
bug with a linked issue.
