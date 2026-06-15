# Enums

Pure vs. backed enums, when (and how) to add a backing type, why display labels live in attributes rather than the
backed value, pure enum methods, `from()`/`tryFrom()`, `enum_values()`, and enums vs. class constants.

## Default to a pure (unbacked) enum

Start with a pure enum. A pure case is already a first-class value in PHP's type system — it carries identity, is
impossible to forge, and is caught by `match` exhaustiveness — without needing any serialized representation. Add a
backing type only when you discover a concrete reason to.

```php
// ✅ Pure enum: a closed set used only at runtime
enum OrderStatus
{
    case Pending;
    case Processing;
    case Shipped;
    case Cancelled;
}
```

## Back an enum only when the value crosses a boundary

Add a backing type when, and only when, the value must leave the process: a database column, an API payload, a
configuration file, a queue message. The backed value is the _external reference_ that maps back to the case.

```php
// ✅ Backed: the case is persisted in a database column
enum OrderStatus: string
{
    case Pending    = 'pending';
    case Processing = 'processing';
    case Shipped    = 'shipped';
    case Cancelled  = 'cancelled';
}
```

The decision tests:

> **Does this value need to survive outside the current process?** Runtime-only → pure. Persisted or transmitted →
> backed.

> **Can or will this backed value ever change?** If yes, reconsider — changing a backed value is a data migration.

### Prefer string backing over int

String-backed enums are self-documenting in storage, logs, and payloads (`'shipped'` explains itself; `3` requires a
lookup table). Back with `int` only when an external system demands integers (a legacy column, a binary protocol) or
when the ordinal position is itself meaningful.

```php
// ❌ A string constant masquerading as a type — typos pass silently
class PostStatus
{
    public const string DRAFT     = 'draft';
    public const string PUBLISHED = 'published';
}
publish('publihsed'); // accepted; bug ships

// ✅ The enum IS the type — typos are analysis-time errors
enum PostStatus: string
{
    case Draft     = 'draft';
    case Published = 'published';
    case Archived  = 'archived';
}
publish(PostStatus::Published); // unambiguous, unforgeable
```

## Store display labels in attributes, not the backed value

The backed value is a **stable external key**. A human-readable label is **metadata** that may change at any time.
Overloading the backed value as a label couples a UI string to your persistence layer — renaming a label becomes a
breaking database migration.

```php
// ❌ Label IS the backed value — renaming "Pending Review" rewrites every stored row
enum OrderStatus: string
{
    case Pending = 'Pending Review';
    case Shipped = 'Out for Delivery';
}

// ✅ Backed value is a stable key; the label is attribute metadata
#[\Attribute(\Attribute::TARGET_CLASS_CONSTANT)]
final readonly class Label
{
    public function __construct(public string $text) {}
}

enum OrderStatus: string
{
    #[Label('Pending Review')]
    case Pending = 'pending';

    #[Label('Out for Delivery')]
    case Shipped = 'shipped';

    public function label(): string
    {
        $reflection = new \ReflectionEnumBackedCase(self::class, $this->name);
        $attributes = $reflection->getAttributes(Label::class);

        return $attributes[0]->newInstance()->text;
    }
}
```

Attributes also colocate the data _with the case it describes_ and scale to many properties (label, color, icon) by
adding more attributes — whereas a `match` arm per property pushes the data away from the case and forces a new `match`
expression for every attribute.

```php
// ❌ Does not scale — each property is a separate match, far from the case
public function label(): string
{
    return match ($this) {
        self::Pending => 'Pending Review',
        self::Shipped => 'Out for Delivery',
    };
}
```

Resolve attributes through reflection once and cache the result if it is read on a hot path — reflection is not free,
and
attributes are metadata, not a runtime control-flow mechanism.

## Enum methods are pure

Enums may carry methods that compute from the case or its metadata. Those methods must be **pure relative to the enum**:
no injected dependencies, no side effects. An enum that needs a service is a discriminator for a class hierarchy, not
the
home for the behavior.

```php
enum OrderStatus: string
{
    case Pending   = 'pending';
    case Shipped   = 'shipped';
    case Cancelled = 'cancelled';

    public function isTerminal(): bool
    {
        return match ($this) {
            self::Shipped, self::Cancelled => true,
            self::Pending                  => false,
        };
    }
}
```

## `from()` (throws) vs. `tryFrom()` (returns null)

Backed enums ship two construction methods. Choose by trust:

| Method            | Input                                                 | Behavior                                                       |
| ----------------- | ----------------------------------------------------- | -------------------------------------------------------------- |
| `from($value)`    | A value you already trust (internal, post-validation) | Returns the case, **throws** `\ValueError` on an unknown value |
| `tryFrom($value)` | Untrusted input (decoded JSON, request data)          | Returns the case, or **`null`** on an unknown value            |

```php
// At the boundary: untrusted input, decide what an unknown value means
$status = OrderStatus::tryFrom($payload['status'])
    ?? throw new \UnexpectedValueException("Unknown status: {$payload['status']}");

// Inside the domain: the value is already trusted
$status = OrderStatus::from($trustedColumnValue);
```

Wrapping these in named methods (`instance()` for the throwing path, `parse()` for the nullable path) is reasonable when
you want a stable API that does not change if the mechanism does — but the bare `from`/`tryFrom` are the defaults.

## `enum_values()` for extracting backed values

When building a `WHERE … IN` clause or a validation allow-list, extract the backed values rather than mapping cases by
hand:

```php
use function App\Enum\enum_values;

$visible = enum_values(PostStatus::Published, PostStatus::Draft); // ['published', 'draft']
$all     = enum_values(...PostStatus::cases());                   // ['draft', 'published', 'archived']
```

## Enums vs. class constants

A class constant representing a member of a closed set is a code smell — it is a stringly-typed value with no type,
identity, or exhaustiveness checking. Convert it to an enum. Reserve `const` for genuine _single_ configuration values
(a default depth, a hash algorithm), not for a family of related options.

```php
// ❌ A closed set expressed as constants
final class Suit
{
    public const string HEARTS = 'H';
    public const string SPADES = 'S';
    // ... callers pass raw strings, typos pass, no exhaustiveness
}

// ✅ A closed set is an enum
enum Suit: string
{
    case Hearts = 'H';
    case Spades = 'S';

    // Enums may still hold a genuine single constant
    public const string DEFAULT = self::Hearts->value;
}
```

An enum cannot be extended or instantiated and has no constructor — it is not a substitute for a class hierarchy. If
case-specific behavior grows complex, model it with polymorphic classes and use the enum as the discriminator.
