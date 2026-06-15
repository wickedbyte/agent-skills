# Value Objects and Immutability

`final readonly` value objects, the entity distinction, self-validating constructors that normalize then validate,
named constructors in the `from()`/`tryFrom()` vocabulary, the wither pattern, and PHP 8.4/8.5 derived-value tools.

## Table of contents

- [Value object vs. entity](#value-object-vs-entity)
- [`final readonly class`](#final-readonly-class)
- [Promotion vs. declared/derived properties](#promotion-vs-declaredderived-properties)
- [Constructors are public and self-validating](#constructors-are-public-and-self-validating)
- [Normalize, then validate — in the constructor body](#normalize-then-validate--in-the-constructor-body)
- [Named constructors: the `from`/`tryFrom`/`make` vocabulary](#named-constructors-the-fromtryfrommake-vocabulary)
- [Producing a changed copy: the wither pattern](#producing-a-changed-copy-the-wither-pattern)
- [`__toString` / `Stringable`](#tostring--stringable)
- [Property hooks for derived values (8.4)](#property-hooks-for-derived-values-84)

## Value object vs. entity

A **value object** is defined by its _values_: two instances with the same values are interchangeable. It is immutable,
self-validating, carries no identity, and depends on nothing. An **entity** is defined by its _identity_: two entities
with identical data but different IDs are different things, it has a mutable lifecycle, and it is **not** `readonly`.

```php
// Value object — equality by value
$a = EmailAddress::from('user@example.com');
$b = EmailAddress::from('user@example.com');
// $a and $b are the same thing

// Entity — equality by identity
$u1 = new User(UserId::from('abc'), $a);
$u2 = new User(UserId::from('xyz'), $a);
// different users despite the same email
```

The dividing line is which invariants belong where. A value object enforces **intrinsic** constraints — those decidable
from the value alone (an email is well-formed, money is non-negative). **Extrinsic** constraints — uniqueness, "this
email is already taken," anything needing a database or other entities — live in the entity or persistence layer, never
in the value object. The moment a value object would need a `UserRepository` to validate itself, it is not a value
object.

```php
// ❌ Value object reaching for external context — it is no longer a value object
final readonly class EmailAddress
{
    public function __construct(
        public string $value,
        private UserRepository $users, // value objects have no dependencies
    ) {
        $this->users->existsByEmail($value) && throw new EmailAlreadyTaken($value);
    }
}

// ✅ The type guarantees format; the database unique index guarantees uniqueness
final class User // entity: not readonly
{
    public function __construct(
        public readonly UserId $id,
        private EmailAddress $email,
    ) {}
}
```

## `final readonly class`

Value objects, DTOs, and domain events are `final readonly class`. `readonly` is _intentional signaling_, not a
mechanical optimization: it declares "immutability is the defining characteristic of this type." `final` protects the
equality semantics — a subclass could otherwise change what "equal" means and break Liskov substitution. The combination
is the natural shape for any type defined by its values.

```php
final readonly class Money
{
    public function __construct(
        public string $currency,
        public int $minorUnits,
    ) {}
}
```

A `readonly class` makes all declared properties implicitly `readonly`; it does **not** require them all to be promoted.
Non-promoted properties are allowed — they must simply be assigned exactly once, in the constructor body. Note that
`readonly class` blocks PHPUnit's `createMock()` (mocking needs to add state), which is fine: value objects are tested
with real instances, never mocked.

### When you need property hooks: drop to per-property `readonly`

`final readonly class` is sugar for marking every declared property `readonly`. A **hooked** property — including a
get-only _virtual_ property — cannot be `readonly`: PHP rejects it with _"Hooked properties cannot be readonly"_, and a
`readonly class` would force that modifier onto it. So the class-level form and property hooks are mutually exclusive.

This is not a reason to avoid hooks — they are genuinely useful on value objects (derived accessors, validated setters
under asymmetric visibility). When a value object needs them, declare it as a plain `final class` and put `readonly` on
each _stored_ property individually, leaving the hooked properties un-`readonly`:

```php
// ❌ Fatal error: a readonly class cannot contain a hooked property
final readonly class EmailAddress
{
    public string $domain {
        get => \substr($this->value, \strpos($this->value, '@') + 1);
    }
    public function __construct(public string $value) {}
}

// ✅ final class + per-property readonly; the virtual $domain hook is un-readonly
final class EmailAddress implements \Stringable
{
    public readonly string $value;

    public string $domain {
        get => \substr($this->value, \strpos($this->value, '@') + 1);
    }

    public function __construct(string $value)
    {
        // normalize + validate, then assign the stored property once
        $this->value = \strtolower(\trim($value));
    }

    public function __toString(): string
    {
        return $this->value;
    }
}
```

Prefer the class-level `readonly` form for value objects that have no hooks; reach for per-property `readonly` only when
a hook requires it. The immutability guarantee is identical either way — it just moves from the class keyword onto the
individual stored properties.

## Promotion vs. declared/derived properties

Constructor property promotion is the default — it eliminates the `$this->x = $x` boilerplate. **Never declare and
promote the same property.** Drop to a _declared_ property assigned in the constructor body in exactly two cases:

1. **The constructor derives a property** from its inputs (a promoted parameter cannot be reassigned in the body).
2. **The constructor coerces a wide input** to a narrow property type (the parameter type and property type differ).

```php
final readonly class TombstoneActivated
{
    // Derived properties: declared, assigned once in the body
    public string $reference;
    public string $id;

    public function __construct(
        public string $message,    // promoted
        public StackFrame $caller, // promoted
    ) {
        $this->reference = $this->caller->class . $this->caller->type . $this->caller->function;
        $this->id        = \hash('xxh3', $this->reference . $message);
    }
}
```

```php
// Wide-input coercion: parameters accept several forms, properties hold the canonical type
final readonly class OrderShipped
{
    public OrderId $orderId;
    public EmailAddress $customerEmail;

    public function __construct(
        OrderId|\Stringable|string $orderId,
        EmailAddress|\Stringable|string $customerEmail,
        public \DateTimeImmutable $shippedAt,
    ) {
        $this->orderId       = OrderId::from((string) $orderId);
        $this->customerEmail = EmailAddress::from((string) $customerEmail);
    }
}
```

If passing arbitrary `string $orderId` _feels_ wrong, that instinct is correct: the fix is a value object that validates
once, not scattered validation. Once you hold an `OrderId`, it is valid everywhere.

## Constructors are public and self-validating

Constructors are **public** by default. A private constructor breaks the `new ClassName()` default-parameter-expression
pattern (PHP 8.1+), which is how value objects give events and entities auto-generated, overridable defaults:

```php
final readonly class CorrelationId implements \Stringable
{
    public string $value;

    public function __construct(string|null $value = null)
    {
        $this->value = $value ?? \bin2hex(\random_bytes(16));
        $this->value !== '' || throw new \UnexpectedValueException('CorrelationId cannot be empty');
    }

    public function __toString(): string { return $this->value; }
}

final readonly class OrderProcessed
{
    public function __construct(
        public OrderId $orderId,
        public CorrelationId $correlationId = new CorrelationId(), // needs a public constructor
        public \DateTimeImmutable $occurredAt = new \DateTimeImmutable(),
    ) {}
}
```

Make the constructor `private` only when subclasses must call `new static()` via late static binding (the public surface
is then named constructors), or `protected` on an abstract base whose constructor is shared but not called directly.
Constructors **initialize state only**: no I/O, no events, no service calls, no injected dependencies — those belong in
factories or services.

## Normalize, then validate — in the constructor body

The self-valid contract is: _if you hold an instance, it is valid and canonical._ That guarantee only holds if
normalization and validation live in the **constructor body**, where every construction path — `new`, `new static()`, a
default expression — must pass through them. Put them in a `from()` named constructor _only_ and a direct `new` bypasses
them, splitting your type into "validated" and "maybe-validated" instances.

Always **normalize first, then validate the normalized form** — validating raw input produces confusing errors on
technically-valid values (e.g. an email with stray whitespace).

```php
// ✅ Constructor body enforces the invariant on every path
final readonly class EmailAddress implements \Stringable
{
    public string $value;

    public function __construct(string $value)
    {
        $this->value = \strtolower(\trim($value));            // 1. normalize

        $this->value !== ''                                    // 2. validate the normalized form
            || throw new \InvalidArgumentException('Email address cannot be empty');

        \filter_var($this->value, \FILTER_VALIDATE_EMAIL)
            || throw new \InvalidArgumentException(\sprintf('Invalid email address: %s', $this->value));
    }

    public function __toString(): string { return $this->value; }
}
```

```php
// ❌ Normalization only in from() — new EmailAddress('User@X.COM ') stores it raw
final readonly class EmailAddress
{
    public function __construct(public string $value) {}

    public static function from(string $value): self
    {
        return new self(\strtolower(\trim($value)));
    }
}
```

## Named constructors: the `from`/`tryFrom`/`make` vocabulary

Named constructors mirror PHP's own `BackedEnum` API, so the mental model is already familiar:

| Method                     | Contract                                              |
| -------------------------- | ----------------------------------------------------- |
| `from($value)`             | Construct and validate; **throws** on invalid input   |
| `tryFrom($value)`          | Construct; returns **`null`** on invalid input        |
| `make()` / `of()`          | General-purpose factory, when it reads more naturally |
| `draft()`, `activate()`, … | Descriptive domain action with business meaning       |

**The parameter _type_ communicates the input format — never encode it in the name.** `from(string $value)` already
says the input is a string; `fromString()` repeats it. This rule is universal: if the type is visible in the signature,
the name must not restate it.

```php
// ❌ Redundant — the parameter type already says "string"
public static function fromString(string $value): self { /* ... */ }

// ✅ The type carries the format
public static function from(string $value): self { /* ... */ }
public static function from(array $data): self { /* ... */ }
```

A named constructor may accept a **wide input** for ergonomics and coerce to the canonical type — but the real
constructor must still enforce the invariant independently:

```php
public static function from(self|\Stringable|string $value): self
{
    if ($value instanceof self) {
        return $value; // already canonical
    }

    return new self((string) $value); // constructor re-validates
}
```

Use `make()` / `of()` when they read better (`Money::of(100, Currency::USD)`), and a descriptive name when construction
is a _domain action_ rather than a data conversion (`Invoice::draft(...)`, `UserSession::initiate(...)`). `from` is for
"input type → value object"; a verb is for "create this aggregate with business meaning."

## Producing a changed copy: the wither pattern

Immutability means returning a _new_ instance rather than mutating. On PHP **8.5**, use the clone-with expression, which
takes an **associative array of property overrides**:

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
        return clone($this, ['alpha' => $alpha]); // PHP 8.5 — the array form is the shipped syntax
    }
}
```

> **Syntax note.** The shipped 8.5 syntax is `clone($object, ['prop' => $value])` — an associative array of overrides.
> An earlier RFC draft used a brace block (`clone($obj){ alpha: 255 }`); that form **never shipped**. Always use the
> array form.

Before 8.5 (or for a library whose floor is lower), use explicit `with*` methods that return `new self(...)`:

```php
public function withAlpha(int $alpha): self
{
    return new self(red: $this->red, green: $this->green, blue: $this->blue, alpha: $alpha);
}
```

A single `with(...)` method using named parameters and `??` is tempting but **breaks on nullable properties** —
`$x ?? $this->x` cannot tell "caller passed `null` deliberately" from "caller omitted the argument." When any property
is
nullable, use per-property withers or 8.5 clone-with. Reach for a mutable builder only when construction is genuinely
complex (many optional fields, cross-field validation that needs all values present first) — it is not the default.

## `__toString` / `Stringable`

`__toString()` is the _internal_ string form — analogous to Rust's `Debug` — for logging, exception messages, and
interpolation. It is **not** the user-facing display. A value object whose backing is a single string scalar (`OrderId`,
`Slug`, `EmailAddress`) is the natural place for it. Any class with `__toString()` must explicitly `implements
\Stringable` so the capability shows up in type hints and PHPStan can verify it.

```php
final readonly class OrderId implements \Stringable
{
    public function __construct(public string $value) {}

    public function __toString(): string { return $this->value; } // "ord-abc123"
}
```

Do **not** add `__toString()` where the representation is ambiguous or lossy — a `Money` could render as `100`, `$1.00`,
or `1.00 USD`. There, use explicit named methods (`format()`, `toIsoString()`) and let the caller pick.

## Property hooks for derived values (8.4)

PHP 8.4 property hooks let a _derived_ value be read as a property instead of a method, even when the backing logic is
non-trivial. This replaces the old getter-for-a-computed-value pattern. Hooks compute from already-normalized state —
they are not the primary normalization site.

A hooked property cannot be `readonly`, so a value object that uses hooks is a plain `final class` with per-property
`readonly` on its _stored_ fields (see "When you need property hooks" above) — not a `final readonly class`:

```php
final class EmailAddress implements \Stringable
{
    public readonly string $value; // stored: readonly

    public string $domain {        // virtual/derived: cannot be readonly
        get => \substr($this->value, \strpos($this->value, '@') + 1);
    }

    public function __construct(string $value) { /* normalize + validate, assign $this->value once */ }

    public function __toString(): string { return $this->value; }
}

$email = EmailAddress::from('user@example.com');
$email->domain; // 'example.com'
```

Avoid a `value()` accessor that merely returns `$this->value` — it is noise. Expose the `public readonly` property
directly; only write a `value()` method when an interface requires it (and then _also_ expose the property) or when the
method genuinely transforms.
