# Application Patterns

PSR-15 middleware over immutable PSR-7, RFC 7807 error responses, PSR-3 structured logging, caching as a decorator, the
message bus, domain events, dispatched side effects, and capped cursor pagination.

> **Framework conventions take precedence over everything in this file.** These are the PSR-based defaults for a
> framework-agnostic application (or a library/microframework that wires its own HTTP stack). A full framework brings
> its own equivalents and you should use _those_: Laravel has its own `Middleware` contract (not PSR-15), the `Log`
> facade / channels (not a hand-injected PSR-3 logger), Eloquent, and its own exception-rendering and pagination;
> Symfony has kernel event subscribers, Monolog channels, Doctrine, and Serializer/ProblemNormalizer. Apply the patterns
> below only where the framework leaves the choice to you (most often inside the domain/application layer that the
> framework doesn't dictate). Don't replace working framework-idiomatic HTTP, logging, or routing code with these.

## Contents

- [PSR-15 middleware and PSR-7 immutability](#psr-15-middleware-and-psr-7-immutability)
- [RFC 7807 problem details](#rfc-7807-problem-details)
- [PSR-3 structured logging](#psr-3-structured-logging)
- [Caching as a decorator](#caching-as-a-decorator)
- [Message bus and repositories](#message-bus-and-repositories)
- [Domain events](#domain-events)
- [Dispatched side effects](#dispatched-side-effects)
- [Cursor pagination with capped limits](#cursor-pagination-with-capped-limits)

## PSR-15 middleware and PSR-7 immutability

A PSR-15 middleware's `process()` returns a `ResponseInterface`, so a middleware that acts on the response calls
`$handler->handle($request)` first, then operates on what comes back up the stack. PSR-7 messages are **immutable** —
every `with*()` returns a _new_ instance, so a middleware never mutates a request or response, it derives one.

```php
public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
{
    $response = $handler->handle($request);

    return $response->withHeader('X-Correlation-ID', (string) $this->correlationId); // new instance
}
```

**WHY ordering matters.** Middleware that shapes the _response_ (correlation ID, error transformation, response
logging) must run **early/outermost** so the response it returns is the one the client actually receives, including
error responses produced downstream. Middleware that gates the _request_ (auth, rate limiting, parsing) runs nearer the
handler. A typical outer-to-inner order: correlation ID → error transformation → authentication → request validation →
handler.

## RFC 7807 problem details

Every HTTP API error response is an RFC 7807 problem-details document with media type
**`application/problem+json`** (not `application/json` — the distinct type lets clients detect problems without parsing
the body).

```json
{
    "type": "https://example.com/problems/order-not-found",
    "title": "Order Not Found",
    "status": 404,
    "detail": "No order with ID ord-abc123 exists.",
    "instance": "/orders/ord-abc123",
    "errors": { "customer_id": ["Customer ID is required."] }
}
```

`type` identifies the problem _class_ (a stable URI resolving to docs, or `about:blank`), not the occurrence; `title`
is stable across occurrences; `detail` and `instance` are occurrence-specific. Application-specific context goes in
extension fields (e.g. `errors`). The correlation ID travels in the `X-Correlation-ID` **header**, never the body.

```php
// ❌ Ad-hoc shapes, and a leaked stack trace / internal class name
{ "error": "not found" }
{ "exception": "App\\Domain\\Order\\OrderNotFound", "trace": "..." }
```

Never expose stack traces or internal class names — they leak implementation detail and are a security concern; they
belong in logs. An error-transformation middleware converts an internal `HttpExceptionResponse` into the format
negotiated from the `Accept` header (problem+json for JSON, equivalent HTML/text strategies otherwise).

## PSR-3 structured logging

Inject `Psr\Log\LoggerInterface` with a `new NullLogger()` default (see `references/architecture-and-di.md`). Pass
**structured context** as an array; never interpolate values into the message string. The message stays a constant
template with `{placeholder}` tokens, which keeps log lines groupable and the variable data machine-queryable.

```php
// ❌ Interpolated message: every line is unique, context is unqueryable
$logger->info("User {$userId} placed order {$orderId}");

// ✅ Constant template + structured context
$logger->info('User {id} placed order {order}', ['id' => $userId, 'order' => $orderId]);
```

Use PSR-3 levels with their intended semantics, and do **not** use `error` for an expected business outcome — an order
failing validation is a `warning` or `notice`, not an `error`. Secrets never appear in any log, even at `debug`.

Do not unit-test that a logger was called — a log call is not observable behavior from the caller's view, and the
`NullLogger` default means tests ignore logging with no mock setup. When an integration test must verify a log
(audit-trail behavior), inject `Psr\Log\Test\TestLogger` and inspect its records.

## Caching as a decorator

Caching is applied as a **decorator** wrapping a repository or service behind the _same_ interface — never sprinkled
inline at call sites. Callers inject the interface and transparently receive the cached version; adding or removing the
cache changes only the container binding, not a single line of calling code.

```php
final class CachingUserMetadataRepository implements UserMetadataRepository
{
    public function __construct(
        private readonly UserMetadataRepository $inner,
        private readonly \Psr\SimpleCache\CacheInterface $cache,
    ) {}

    public function find(int $userId): ?User
    {
        $key = 'user_metadata.' . $userId;
        $cached = $this->cache->get($key);
        if ($cached instanceof User) {
            return $cached;
        }

        $user = $this->inner->find($userId);
        if ($user instanceof User) {
            $this->cache->set($key, $user);
        }

        return $user;
    }
}
```

Prefer **PSR-16** (`Psr\SimpleCache\CacheInterface`) for simple get/set/delete in a decorator; reach for **PSR-6**
(`Psr\Cache\CacheItemPoolInterface`) only when the backend's metadata features (tagging, deferred writes) are needed.
Add caching only against a _measured_ need — cache-invalidation bugs are subtle, and a speculative cache is maintenance
burden with no proven benefit. TTL is the first invalidation defense; for must-be-fresh data, attach a synchronous
invalidation listener to the event that mutates it, keyed deterministically (`user_metadata.{id}`) so the listener
derives the same key the population path wrote.

## Message bus and repositories

A **single unified bus** dispatches both commands and domain events — there is no separate command bus and event bus.
The command/event distinction is a naming and handler-registration convention (a command has exactly one handler; an
event has zero or many), not an infrastructure boundary.

```php
$bus->dispatch(new PlaceOrder($orderId, $customerId, $items)); // command — one handler
$bus->dispatch(new OrderPlaced($orderId, $occurredAt));        // event — zero or many handlers
```

There is **no query bus**: reads are encapsulated in **repository** classes exposing typed, named methods
(`$orders->findByCustomer($id)`), which compose naturally with an ORM and avoid a serialization layer for the read
side. Event handlers must not throw in a way that rolls back the originating transaction — a failing listener logs and
recovers. Route PSR-14 _notification_ events through `Psr\EventDispatcher\EventDispatcherInterface` directly; reserve
the message bus for commands and domain events that need middleware (transactions, retries, logging).

## Domain events

A domain event is a **fact** — something that already happened. Name it `SubjectPastTenseVerb`, with **no** `Event`
suffix and no `On` prefix: `OrderShipped`, `PaymentProcessed`, `UserRegistered` — never `OrderShippedEvent` or
`OnOrderShipped`. The namespace plus the past-tense name carries the meaning.

```php
final readonly class OrderPlaced implements \JsonSerializable
{
    public function __construct(
        public OrderId $orderId,
        public \DateTimeImmutable $occurredAt,
    ) {}

    /** @return array{order_id: string, occurred_at: string} */
    public function jsonSerialize(): array
    {
        return ['order_id' => (string) $this->orderId, 'occurred_at' => $this->occurredAt->format(\DATE_RFC3339)];
    }
}
```

Events are `final readonly` value objects (the one tolerated exception is a PSR-14 `StoppableEventInterface` propagation
flag, which is per-property `readonly` with one intentionally mutable `$propagate`). Compute derived properties in the
constructor body and assign them to `readonly` fields — not in a getter that recomputes on every access. Events that
cross a process boundary implement `\JsonSerializable` (see `references/attributes-and-serialization.md`). When an app
mixes PSR-14 application events with event-sourced domain events, disambiguate with `#[Psr14Event]` /
`#[EventSourcedEvent]` attributes, not empty marker interfaces.

## Dispatched side effects

Anything that is **not** the core of the current request — confirmation email, webhook, search-index update, analytics,
audit log — is **dispatched** as a message, never performed with inline I/O in the handler. The heuristic for a REST
API: everything except the primary CRUD operation is a side effect.

```php
// ❌ Inline I/O blocks the response and couples the handler to the mailer
public function place(PlaceOrder $command): void
{
    $order = Order::place(/* ... */);
    $this->orders->save($order);
    $this->mailer->sendOrderConfirmation($order);
}

// ✅ Enqueue the side effect; the handler stays fast and decoupled
public function place(PlaceOrder $command): void
{
    $order = Order::place(/* ... */);
    $this->orders->save($order);
    $this->bus->dispatch(new SendOrderConfirmationEmail($order->id));
}
```

Whether a dispatched message runs synchronously (dev/test) or on a background worker (production) is a **bus
configuration** detail — the dispatching code is identical in both, and no application code changes when switching. In
tests, assert the message was _dispatched_ (using a collecting bus), never inject a real mailer; the handler is tested
independently.

(Soft deletes, when unavoidable outside an event-sourced model, use a nullable `deleted_at TIMESTAMPTZ` with a partial
index over `WHERE deleted_at IS NULL` — it records both state _and_ time — never a boolean `is_deleted` or a `Deleted`
enum case that conflates lifecycle with domain status. The recurring need for soft deletes is itself a hint the domain
wants event sourcing.)

## Cursor pagination with capped limits

Pagination is added **defensively, before** an unbounded result set causes an incident — never paginate in the
application layer after fetching the whole table. Every repository method returning a collection takes a pagination
parameter or is otherwise bounded.

Prefer **cursor/keyset** pagination over limit/offset: it seeks directly to the next page instead of scanning and
discarding rows, so performance does not degrade at high offsets.

```php
interface OrderRepository
{
    public function findRecent(?Cursor $after = null, int $limit = 25): CursorPage;
}

final readonly class CursorPage
{
    public function __construct(
        /** @var list<Order> */
        public array $items,
        public ?Cursor $nextCursor,
        public bool $hasMore,
    ) {}
}
```

The cursor is an opaque token (encoding the last row's sort keys) returned with each page and passed back for the next.
When the API requires random-access page navigation or the sort order has no stable keyset, fall back to limit/offset —
but the **limit always has a maximum cap enforced in the repository/service**, never trusted raw from user input.

```php
/**
 * @param positive-int $limit
 * @param int<0, max> $offset
 * @return list<Order>
 */
public function findByCustomer(CustomerId $id, int $limit = 25, int $offset = 0): array;
```

Apply one pagination strategy uniformly across an API — mixing cursor and offset forces consumers to implement two
patterns. Collections themselves are docblock-typed arrays (`list<T>`) by default; accept `iterable<T>` on public
params that only iterate, and introduce a named collection class only for wide reuse, runtime element validation, or
domain methods beyond iteration.
