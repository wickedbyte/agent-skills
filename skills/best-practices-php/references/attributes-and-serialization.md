# Attributes and Serialization

Attributes are metadata only; serialization is always explicit. Resolve attributes once and cache; implement
`\JsonSerializable` on every serialized object and add a `from(array)` constructor to round-trip.

## Attributes describe what something _is_, never what it _does_

An attribute attaches **metadata** to a target (class, method, property, parameter, constant). It must not be the
mechanism that _runs_ logic. Reflecting attributes is reflection, and reflection is slow — so resolve an attribute
**once**, cache the result, and never read it inside a hot path or a loop. Crucially, attributes must never drive
control flow or wire the DI container.

| Legitimate use                      | Example                                                                      |
| ----------------------------------- | ---------------------------------------------------------------------------- |
| Enum case labels / display metadata | `#[Label('Draft — not yet visible')]` on a case                              |
| ORM / persistence mapping           | `#[ORM\Column(...)]`, `#[ORM\Id]` on entity properties                       |
| Stability & intent markers          | `#[Internal]`, `#[Experimental]`, `#[Contract]`, `#[HotPath]`                |
| Disambiguation tags                 | `#[Psr14Event]` vs `#[EventSourcedEvent]` instead of empty marker interfaces |
| Rename protection                   | `#[StableClassName]` on a class whose FQCN is persisted externally           |
| Signature-drift guard               | `#[\Override]` (PHP 8.3+)                                                    |

```php
#[\Attribute(\Attribute::TARGET_CLASS_CONSTANT)]
final readonly class Label
{
    public function __construct(public string $value) {}
}

enum Status
{
    #[Label('Draft — not yet visible')]
    case Draft;

    #[Label('Published — live to readers')]
    case Published;
}
```

**WHY labels go in attributes, not in the backed value.** The backed value (`'draft'`) is an external reference — a DB
column, an API field — and changing it requires a migration. A display label is a UI concern that changes freely. Keep
them in separate places so a copy edit never forces a data migration.

### `#[\Override]` to catch signature drift

Annotate a method that overrides a parent or implements an interface method with `#[\Override]` (PHP 8.3+). If the
parent signature later changes or the method is renamed upstream, the engine raises a fatal error at compile time
instead of silently creating a new, unrelated method. PHP 8.5 extends `#[\Override]` to properties.

```php
final class CachingOrderRepository implements OrderRepository
{
    #[\Override]
    public function find(OrderId $id): ?Order { /* ... */ }
}
```

### Attributes must not wire the container or scatter routes

```php
// ❌ The class now knows about the container — knowledge leaks inward
public function __construct(
    #[Inject('mailer.smtp')] private Mailer $mailer,
) {}

// ✅ The type declares the contract; the container's definition decides the implementation
public function __construct(private Mailer $mailer) {}
```

A type-tagging marker should be an **attribute**, not an empty interface — an interface is a behavioral contract, and a
methodless one purely for `instanceof` misrepresents that. Routing attributes on controllers (`#[Route(...)]`) scatter
the URL map across the codebase; define routes in one place so the structure is visible as a whole.

### Stability and rename markers

```php
#[\Attribute(\Attribute::TARGET_CLASS)]
final readonly class StableClassName
{
    public function __construct(
        public bool $including_namespace = true,
        public bool $externally_referenced = true,
        public string $detail = '',
    ) {}
}
```

`#[StableClassName]` documents that a class's FQCN appears in externally persisted data (a serialized object, an event
stream header) so Rector and contributors do not rename it. (Storing serialized PHP objects with embedded class names
is itself an anti-pattern; the attribute is damage control for when it already happened.)

If an attribute genuinely needs a runtime lookup, a public `static` lookup method co-located on the attribute is the
one acceptable place for non-trivial static logic — it reads from reflection and returns a value:

```php
public static function lookup(AggregateRoot|string $aggregate): self
{
    return attr_first($aggregate, self::class)
        ?? throw new \LogicException(\sprintf('%s lacks the %s attribute', ..., self::class));
}
```

## Serialization is always explicit

### Implement `\JsonSerializable` on every serialized object

Never rely on the default object-to-JSON cast. The cast exposes your internal property structure _as_ the wire format,
so any rename silently becomes a breaking change to consumers. `\JsonSerializable` decouples the internal model from
the serialized shape and makes that shape a declared contract.

```php
// ❌ Shape is an accidental consequence of property names
final readonly class OrderId
{
    public function __construct(public string $value) {}
}
// json_encode(new OrderId('ord-123')) → {"value":"ord-123"}

// ✅ Shape is a deliberate contract
final readonly class OrderId implements \JsonSerializable
{
    public function __construct(public string $value) {}

    public function jsonSerialize(): string
    {
        return $this->value; // serializes as a bare "ord-123", not an object
    }
}
```

### Direction decides the pattern

**Unidirectional** (output only — API responses, event payloads on a queue, log entries): `\JsonSerializable` alone is
enough. No deserializer is needed.

```php
final readonly class OrderProcessed implements \JsonSerializable
{
    public function __construct(
        public OrderId $orderId,
        public \DateTimeImmutable $occurredAt = new \DateTimeImmutable(),
    ) {}

    /** @return array{order_id: string, occurred_at: string} */
    public function jsonSerialize(): array
    {
        return [
            'order_id' => (string) $this->orderId,
            'occurred_at' => $this->occurredAt->format(\DATE_RFC3339),
        ];
    }
}
```

**Bidirectional** (round-tripped — written to a store and read back, exchanged between services): add a static
`from(array $data)` named constructor alongside `jsonSerialize()`. Name it `from()`, never `fromArray()` — the `array`
parameter type already says the input is an array, so the `Array` suffix is redundant (mirror the `from`/`tryFrom`
vocabulary of `BackedEnum`). Decode JSON at the boundary and hand the array to `from()`; do not add a `fromJson()`.

```php
final readonly class TombstoneRecord implements \JsonSerializable
{
    public function __construct(
        public string $id,
        public string $message,
        public \DateTimeImmutable $activatedAt,
    ) {}

    /** @param array{id: string, message: string, activated_at: string} $data */
    public static function from(array $data): self
    {
        return new self(
            id: $data['id'],
            message: $data['message'],
            activatedAt: new \DateTimeImmutable($data['activated_at']),
        );
    }

    /** @return array{id: string, message: string, activated_at: string} */
    public function jsonSerialize(): array
    {
        return [
            'id' => $this->id,
            'message' => $this->message,
            'activated_at' => $this->activatedAt->format(\DATE_RFC3339),
        ];
    }
}
```

A dedicated **hydrator** class earns its keep only when deserialization needs injected dependencies (a repository
lookup during hydration), is complex enough to test independently, or maps several source formats into one class. For
simple structures, the static `from()` on the class is preferred.

For genuinely complex needs — deeply nested graphs, multiple format targets (JSON/YAML/array), version migration,
non-trivial field mapping — reach for **`crell/serde`** rather than hand-rolling, using its `#[Field]` attributes to
declare serialized names:

```php
use Crell\Serde\Attributes\Field;

final readonly class TombstoneRecord
{
    public function __construct(
        public string $id,
        public string $message,
        #[Field(serializedName: 'activated_at')]
        public \DateTimeImmutable $activatedAt,
    ) {}
}
```

## Doctrine entity mapping via attributes

Map Doctrine entities with PHP attributes on the entity class — not XML files and not `@ORM\` docblock annotations.
Attribute arguments are validated by the engine and by static analysis at parse time; docblock annotations are strings
that fail silently. The mapping sits beside the class, so the persistence contract is visible without opening a
separate file.

```php
use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity(repositoryClass: DoctrineOrderRepository::class)]
#[ORM\Table(name: 'orders')]
class Order
{
    #[ORM\Id]
    #[ORM\Column(type: 'string', length: 36)]
    private string $id;

    #[ORM\Column(type: 'string', enumType: OrderStatus::class)]
    private OrderStatus $status;

    #[ORM\Column(type: 'datetimetz_immutable')]
    private \DateTimeImmutable $placedAt;
}
```

Conventions: use `datetimetz_immutable` for every `\DateTimeImmutable` column (never `datetime`); use `enumType` so
Doctrine maps backed enums to and from the column automatically; prefer string UUID identifiers over auto-increment
integers. XML mapping is justified only when the domain model must be usable with **no** Doctrine dependency (a library
that knows nothing of the ORM) — in application code that indirection is wasted. Entities hold mapping metadata and
enforce aggregate invariants; they do not reach outside the aggregate (no service calls, no repository access) — see
`references/architecture-and-di.md`.
