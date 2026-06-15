# Architecture and Dependency Injection

Layered architecture with inward-only dependencies, constructor-injection-only wiring, interface naming, and the
`final` policy.

## Layers and the dependency rule

Organize code into four layers. Dependencies point **inward only** — an outer layer may depend on an inner one, never
the reverse.

| Layer              | Holds                                                                              | May depend on                        | Must never reference                             |
| ------------------ | ---------------------------------------------------------------------------------- | ------------------------------------ | ------------------------------------------------ |
| **Domain**         | Aggregates, value objects, domain events, repository _interfaces_                  | Nothing outside itself               | A PSR container, a framework, concrete I/O, HTTP |
| **Application**    | Command/query handlers, services, use-case orchestration                           | Domain                               | HTTP request/response, framework base classes    |
| **Infrastructure** | Persistence, messaging, HTTP clients — adapters that _implement_ domain interfaces | Domain (the interfaces it satisfies) | Application, Presentation                        |
| **Presentation**   | Controllers, console commands, message handlers                                    | Application                          | —                                                |

The test of a clean boundary: _if the framework were swapped, how much domain and application code would change?_ The
answer must be **none**. Enforce the rule in code review and by namespace discipline (the domain namespace imports
nothing from infrastructure or the framework). If you want it checked mechanically, an architecture-fitness check — a
PHPStan rule that bans the wrong imports, or a dedicated dependency-boundary linter — can fail the build when a
dependency points the wrong way; treat the tool as a project choice, not a requirement.

```php
// ❌ A framework facade leaking into a domain aggregate
use Illuminate\Support\Facades\Log;

final class Order
{
    public function place(): void
    {
        Log::info('Order placed'); // domain now depends on Laravel
    }
}

// ✅ Domain is pure; the side effect is recorded as an event the application layer dispatches
final class Order
{
    /** @var list<object> */
    private array $events = [];

    public function place(): void
    {
        // domain logic only
        $this->events[] = new OrderPlaced($this->id);
    }
}
```

Two modules (bounded contexts) form a **strict hierarchy**: `Ordering` may depend on `Catalog`, but never the reverse,
and never both. When two modules must react to each other, they communicate through **events on a shared bus**, not
direct class references — see `references/application-patterns.md`.

### Domain interfaces stay in domain terms

A repository interface defined in the domain expresses _what the domain needs_, in domain vocabulary. The
infrastructure adapter supplies the Doctrine/PDO/Redis detail.

```php
// ❌ Infrastructure concept bleeds into the domain contract
interface OrderRepository
{
    public function find(OrderId $id): ?Order;
    public function findByQueryBuilder(QueryBuilder $qb): array; // Doctrine leaks in
}

// ✅ Pure domain concepts; the adapter decides how to query
interface OrderRepository
{
    public function find(OrderId $id): ?Order;

    /** @return list<Order> */
    public function findByCustomer(CustomerId $id): array;
}
```

## Constructor injection only

Every dependency arrives through the constructor. No service locator, no setter injection, no property injection, and
no autowiring magic reaching into domain code.

```php
// ❌ Setter injection — a partially wired object exists between construction and the setter
$processor = new OrderProcessor();
$processor->setRepository($orders);
$processor->setLogger($logger);
// any call to $processor->process() before the setters run hits a null dependency

// ❌ Property injection — the class lies about what it needs
final class OrderProcessor
{
    #[Inject]
    private OrderRepository $orders; // invisible dependency; constructor says "nothing required"
}

// ✅ Constructor injection — dependencies are visible, required, and immutable
final class OrderProcessor
{
    public function __construct(
        private readonly OrderRepository $orders,
        private readonly LoggerInterface $logger = new NullLogger(),
    ) {}
}
```

**WHY explicit over autowiring.** Autowiring inspects constructor signatures by reflection on every cold resolution and
weakens inversion of control: the class implicitly controls its own wiring through its type hints. Adding a second
implementation of an interface, changing a hint, or renaming a parameter can silently change what gets injected with no
visible change at the call site. Explicit container definitions keep that decision in the configuration, where it is
greppable and serves as a readable map of the dependency graph.

```php
// ✅ Explicit definition: which implementation satisfies which need is stated, not inferred
$container->bind(OrderProcessor::class, static fn (Container $c): OrderProcessor => new OrderProcessor(
    orders: $c->get(OrderRepository::class),
    logger: $c->get(ApplicationLogger::class),
));
```

If setter injection feels necessary, that is a design signal: either construction is complex enough to deserve a
**builder**, or an "optional dependency set later" is really a constructor parameter with a sensible default (often a
Null Object). Domain code never references `Psr\Container\ContainerInterface` — injecting the container is a service
locator in disguise and hides the real dependencies.

### Logging is injected, not mixed in

Inject `Psr\Log\LoggerInterface` with a `new NullLogger()` default. Do **not** reach for `LoggerAwareTrait` /
`LoggerAwareInterface`: setter-style logger wiring reintroduces the partially-wired window and makes the dependency
optional-at-runtime rather than declared.

```php
// ✅ The logger is a real, defaulted dependency — the class works with or without a configured logger
public function __construct(
    private readonly PaymentGateway $gateway,
    private readonly LoggerInterface $logger = new NullLogger(),
) {}
```

## Interface naming: the clean noun goes to the contract

The interface gets the clean domain noun. Implementations get a **descriptive prefix** that says _which_ one it is. No
`I` prefix, no `Interface` suffix — the `interface` keyword already says so.

```php
interface EventDispatcher
{
    public function dispatch(object $event): void;
}

final class DefaultEventDispatcher implements EventDispatcher {}
final class NullEventDispatcher implements EventDispatcher {}      // no-op (Null Object)
final class CachingEventDispatcher implements EventDispatcher {}   // decorator
final class LoggingEventDispatcher implements EventDispatcher {}   // decorator
final class CollectingEventDispatcher implements EventDispatcher {} // test spy
```

| Prefix                            | Meaning                                      |
| --------------------------------- | -------------------------------------------- |
| `Default`                         | The standard, primary implementation         |
| `Null`                            | A no-op (Null Object pattern)                |
| `InMemory`                        | Non-persistent, for tests and caches         |
| `Caching` / `Logging` / `Tracing` | A decorator adding one cross-cutting concern |
| `Collecting`                      | A test spy that records interactions         |

**Never rename PSR interfaces.** They keep their upstream names — reference `Psr\Log\LoggerInterface`,
`Psr\EventDispatcher\EventDispatcherInterface`, `Psr\Clock\ClockInterface` by canonical FQN. We do not rename what we
do not own. On a name collision between a first-party `EventDispatcher` and PSR's `EventDispatcherInterface`, alias the
PSR one at the import (`use Psr\EventDispatcher\EventDispatcherInterface as EventDispatcherContract;`), local to the
file.

### Classes are nouns; interfaces are narrow

A class name is a noun describing **what it is**. `Manager`, `Helper`, `Util`, `Processor` are placeholders for unclear
modeling — `PostMetadata`, not `PostManager`. Events are past-tense verbs with **no** `Event` suffix (`OrderShipped`,
not `OrderShippedEvent`); exceptions are named after the problem with no `Exception` suffix (`NotFound`).

Prefer **narrow, single-capability** interfaces. A two-method interface is almost always better than a ten-method one:
it is easier to implement, swap, and mock — a one-method interface mocks as a one-method anonymous class. A class
expresses multiple capabilities by implementing multiple interfaces, not by widening one.

Mark stable public-API interfaces with a `#[Contract]` attribute so consumers know it is safe to depend on and changes
require a deprecation cycle. (Attributes stay metadata — see `references/attributes-and-serialization.md`.)

## The `final` policy

| Class type                 | `final`?                          | Reason                                                                             |
| -------------------------- | --------------------------------- | ---------------------------------------------------------------------------------- |
| Value objects, DTOs        | Yes (`final readonly`)            | Equality semantics must not be subclassed                                          |
| Domain events              | Yes (`final readonly`)            | Immutable, no identity, never extended                                             |
| Test classes               | Yes                               | Never extended                                                                     |
| Service classes            | **No**                            | `final` blocks PHPUnit mocking; mock the interface instead                         |
| Security-critical services | Yes, _but implement an interface_ | Subclassing an HMAC signer or password hasher is a risk; LSP is violated by design |
| Abstract classes           | Never                             | Must be extended to mean anything                                                  |

```php
// ❌ A final service cannot be mocked
final class OrderProcessor implements OrderProcessorService {}

// ✅ Non-final service; tests mock the interface, callers still depend on the interface
class OrderProcessor implements OrderProcessorService {}

// ✅ Security-critical: final to forbid dangerous subclasses, but interface-backed so tests can substitute
final class HmacSigner implements Signer {}
final class Argon2IdHasher implements PasswordHasher {}
```

**WHY non-final services.** PHPUnit cannot generate a double for a `final` class. Services are the primary target of
`createMock`/`createStub`, so `final` on a service actively harms testability. Non-final is purely a mocking
affordance — it does not invite inheritance, and callers still type-hint the interface, never the concrete class.

## Thin entrypoints and sparing traits

Controllers, console commands, and message handlers are **thin**: they translate transport input into an application
call, invoke one service/handler, and translate the result back. Business logic does not live in a controller.

```php
// ✅ The controller adapts HTTP; the handler owns the use case
final class PlaceOrderController
{
    public function __construct(private readonly PlaceOrderHandler $handler) {}

    public function __invoke(ServerRequestInterface $request): ResponseInterface
    {
        $command = PlaceOrder::fromRequest($request);
        $orderId = $this->handler->handle($command);

        return new JsonResponse(['id' => (string) $orderId], 201);
    }
}
```

**Static methods** are the exception, not the tool of choice. Instance methods on injected services are the default
because statics are hard to mock and tie behavior to a class rather than a collaborator. The legitimate statics are
named constructors (`from()`/`tryFrom()`) and small **private** pure helpers that touch only their arguments. A public
static method must never produce a side effect — that belongs on an injected service.

Use **traits sparingly**, only for genuinely additive, cross-class behavior (a `WithJsonSerialization` mixed into
unrelated hierarchies). Name them as a capability phrase with a `With` prefix (`WithTimestamps`), never a `Trait`
suffix. When a family of implementations shares a real behavioral contract and a `protected` template API, an
**abstract class** (deferring only the variant method as `abstract protected`) is clearer than interface + trait.
Composition over inheritance remains the default; reach for the abstract class only when every subclass genuinely
_is-a_ variant and Liskov substitution holds.
