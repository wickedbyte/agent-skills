# Date, Time, and Boundaries

`\DateTimeImmutable` in UTC as the application clock, conversion at the request/presentation boundary, parsing untrusted
input with explicit formats, and where validation and secrets belong.

## `\DateTimeImmutable` only for properties and return types

A property type or return type is **always** `\DateTimeImmutable`. `\DateTime` is mutable — a value passed to a method
can be silently mutated by the callee, breaking value-object identity. This is a hard rule with no exceptions.

```php
// ❌ Mutable; a callee can change this object underneath you
public \DateTime $createdAt;
public function createdAt(): \DateTimeInterface { /* ... */ } // too wide — forces instanceof at the call site

// ✅ Immutable property and a precise return type
public readonly \DateTimeImmutable $createdAt;
public function createdAt(): \DateTimeImmutable { return $this->createdAt; }
```

## Accept `\DateTimeInterface` on parameters, coerce to immutable

A **public** API parameter accepts the wide `\DateTimeInterface` so callers may pass either kind, and the method
coerces to immutable before storing it. `\DateTimeImmutable::createFromInterface()` is the standard coercion.

```php
// ✅ Public API: accept wide, store narrow
public function __construct(\DateTimeInterface $createdAt)
{
    $this->createdAt = \DateTimeImmutable::createFromInterface($createdAt);
}

public readonly \DateTimeImmutable $createdAt;
```

For an **internal** class only ever constructed with known types, accept `\DateTimeImmutable` directly — there is no
caller to accommodate, so the wider interface buys nothing.

## UTC is the application timezone — convert only at the boundary

UTC is not merely the storage timezone; it is the _only_ timezone the application's domain ever operates in. There is
no "convert to UTC before saving" step because every `\DateTimeImmutable` inside the domain is already UTC. Expressing
time in any other zone is a **presentation concern**: the server emits UTC, and the client (usually the browser)
renders it in the user's local zone.

When a user submits a local time (a form field with no offset), convert it to UTC during request validation/coercion,
_before_ it reaches the domain. No domain object ever receives a non-UTC time.

```php
// ❌ A non-UTC value leaks into the domain
$command = new ScheduleOrder($orderId, new \DateTimeImmutable($request->get('scheduled_at')));

// ✅ Coerce to UTC at the request boundary; the domain receives only UTC
$local = new \DateTimeImmutable($request->get('scheduled_at'), $userTimeZone);
$utc = $local->setTimezone(new \DateTimeZone('UTC'));
$command = new ScheduleOrder($orderId, $utc);
```

## Two wire formats — RFC 3339 vs Unix timestamp

| Format             | Use when                                                                                                 | Example                     |
| ------------------ | -------------------------------------------------------------------------------------------------------- | --------------------------- |
| **RFC 3339**       | A human might read it: API responses, logs, error messages, audit trails                                 | `2026-06-15T14:30:00+00:00` |
| **Unix timestamp** | Machine-only and compactness/arithmetic matters: cache TTLs, bus metadata, inter-service protocol fields | `1781793000`                |

```php
$time->format(\DATE_RFC3339);       // 2026-06-15T14:30:00+00:00
$time->format('Y-m-d\TH:i:s.v\Z');  // millisecond precision, explicit Z
$time->getTimestamp();              // integer seconds, machine contexts only
```

RFC 3339 is a profile of ISO 8601 — **always** emit the offset (`+00:00` or `Z`); never a bare datetime with no zone.
A Unix integer such as `1781793000` in a log line is not debuggable, so timestamps never appear in logs or API
responses where a human reads them.

## Inject a `Clock` — never call `new \DateTimeImmutable()` in the domain

Domain and application code must not call `new \DateTimeImmutable()` (or `time()`) directly: a class that reads the wall
clock is non-deterministic and cannot be tested without sleeping or mocking time globally. Inject a PSR-20
`Psr\Clock\ClockInterface` and read "now" from it.

```php
use Psr\Clock\ClockInterface;

final class OrderService
{
    public function __construct(private readonly ClockInterface $clock) {}

    public function place(OrderId $id): OrderPlaced
    {
        return new OrderPlaced($id, $this->clock->now()); // deterministic; testable
    }
}
```

In tests, substitute a frozen clock so time-dependent assertions are exact:

```php
final class FrozenClock implements ClockInterface
{
    public function __construct(private readonly \DateTimeImmutable $now) {}

    public function now(): \DateTimeImmutable
    {
        return $this->now;
    }
}
```

The `new \DateTimeImmutable()` default on an _event_ DTO (
`public \DateTimeImmutable $occurredAt = new \DateTimeImmutable()`)
is tolerable only because the service that creates the event normally passes an explicit clock-derived value; prefer
passing `$clock->now()` so the event timestamp is testable too.

## Parse untrusted input with an explicit format

Never feed untrusted strings to `new \DateTimeImmutable($string)` — its heuristic parser accepts a wide, surprising
range of inputs and silently misreads many. Use `createFromFormat()` with an **explicit** format and treat a `false`
return as a domain error.

```php
// ❌ Heuristic parsing of attacker-controlled input
$date = new \DateTimeImmutable($untrusted);

// ✅ Explicit format; a parse failure is a named domain error
$date = \DateTimeImmutable::createFromFormat('!Y-m-d', $untrusted);
if ($date === false) {
    throw new InvalidDateFormat($untrusted);
}
```

(The leading `!` resets all unspecified fields to the Unix epoch, so a date-only input does not pick up the current
time of day.)

## Request validation vs domain invariants

Two distinct, non-substitutable concerns — **both** happen:

- **Request validation** — framework-facing, at the HTTP boundary. A Form Request (Laravel) or a request hydrator
  (PSR-15) checks that required fields are present and structurally sane, coerces raw input into typed value objects,
  and rejects garbage before it reaches the domain. It validates _shape and presence_, never business rules.
- **Domain invariants** — enforced by value objects and aggregates in their constructors. If an object exists, it is
  valid; if it would be invalid, construction throws. This is a consequence of the type system, not a separate step.

```php
// ❌ Raw request values handed straight to the domain
$order = new Order($request->get('customer_id'), $request->get('total'));

// ✅ Validated and coerced at the boundary; the domain receives typed, valid values
$customerId = CustomerId::from($request->validated('customer_id'));
$total = Money::fromMinorUnits((int) $request->validated('total_cents'), Currency::USD);
$order = new Order($customerId, $total);
```

A value object must **not** call an external service to validate (checking whether a `CustomerId` exists in the
database is application logic for a repository, not a constructor invariant). Conversely, a Form Request must not encode
business rules — those live in the domain model.

## Secrets come from the environment — never logged, never in exceptions

Secrets (API keys, DB passwords) are read from the OS environment, loaded _before_ the PHP process starts (a
supervisor, a secret manager, the platform's secret store — an infrastructure concern). The application does not parse
`.env` on every request. Read each secret **once** at boot into a typed config struct; service classes receive that
struct and never call `getenv()` themselves.

```php
// ❌ Untyped secret read scattered deep in a service
final class StripeClient
{
    public function __construct()
    {
        $this->apiKey = getenv('STRIPE_API_KEY');
    }
}

// ✅ Read once at boot into a typed struct, injected as a dependency
final readonly class StripeConfig
{
    public function __construct(
        public string $apiKey,
        public string $webhookSecret,
    ) {}
}
```

Beyond that: secrets are **never** logged, not even at `debug` level, and **never** placed in an exception message or
an RFC 7807 problem-details response (see `references/application-patterns.md`). `.env.example` carries only key names
and safe placeholders. Because the app reads secrets from the environment, rotation needs only a restart, not a
deploy.
