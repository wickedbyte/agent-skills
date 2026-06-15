---
name: best-practices-php
description: >-
    Use when writing, modifying, or reviewing PHP code (.php files) — including classes, value objects, enums, DTOs,
    services, exceptions, interfaces, traits, attributes, Composer packages, or any PHP-emitting task. Applies to every
    PHP task and targets PHP 8.5. Triggers for strict_types-first conventions, native type declarations everywhere,
    `final readonly` value objects, constructor property promotion, backed enums over class constants, `match` over
    `switch`, exceptions named after the problem, constructor dependency injection (no service locators), PSR interfaces,
    `\DateTimeImmutable` in UTC, PHPStan level max, and PHP 8.5 features (pipe `|>`, clone-with, `#[\NoDiscard]`,
    property hooks, asymmetric visibility). Use this even when the user does not explicitly mention PHP style.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# How to Write PHP

This skill captures an opinionated, framework-agnostic PHP style targeting the language as it stands in mid-2026 (PHP
8.5, PHPStan at `level: max`, the current PHPUnit, a project-chosen coding-standards tool, Composer with committed
lockfiles). Follow it for any PHP work.

> **Tool versions move faster than this document.** PHPUnit, PHPStan, PHP-CS-Fixer, and Rector ship a new major roughly
> yearly. This skill deliberately does **not** pin their version numbers. Use whatever majors the project already
> depends on; when adding tooling to a project that has none, **verify the current stable major yourself** (check
> Packagist / the tool's releases) rather than trusting a number — the conventions below hold across recent majors even
> as the version advances.

## The One Idea

**Modern PHP is a statically-analyzable, type-honest language. Your job is to push every fact about the program out of
the runtime and into the type system, the class structure, and the tooling.** The difference between junior and senior
PHP is not cleverness or new syntax — it is discipline: every file is `strict_types`, every boundary is typed, every
closed set is an enum, every error is a named exception thrown at its source, every value object is `final readonly` and
self-validating, and every dependency arrives through the constructor. You write code that PHPStan at `level: max` can
fully reason about and that reads identically to the next maintainer.

Two consequences shape everything below:

1. **The analyzer is the contract.** If PHPStan cannot prove a property, neither can a reader. Native types, narrow
   docblock generics (`list<T>`, `array<K,V>`), and enums exist so the tool — and the human — can reason without
   running the code.
2. **New syntax earns its place by improving analyzability, never as decoration.** Reach for PHP 8.5 features (the pipe
   operator, clone-with, `#[\NoDiscard]`, property hooks) only where they make code _more_ obvious, not to look modern.

## Framework Conventions Take Precedence

This skill is **framework-agnostic**; a framework's own conventions win wherever they conflict. Laravel and Symfony do
not use PSR-15 middleware, and each has its own idioms for logging, HTTP, routing, naming, and lifecycle — a Laravel
project uses the `Log` facade / a Symfony project the Monolog channel it configured, Eloquent or Doctrine repositories,
the framework's request/response objects, and so on. Follow the framework (and the project's established patterns)
first; apply this skill's guidance to everything the framework leaves open — your domain layer, value objects, enums,
exceptions, types, and the analyzer/test discipline. Do not refactor working framework-idiomatic code toward these
defaults just because they differ.

## When to Use This Skill

Use it for any of:

- Authoring or editing `.php` files — classes, enums, interfaces, traits, functions
- Designing value objects, DTOs, entities, domain events, exception hierarchies
- Wiring services, repositories, message handlers, controllers, console commands
- Setting up or changing `composer.json`, `phpstan.neon`, the coding-standards config (`pint.json`, `phpcs.xml`,
  `.php-cs-fixer.php`), PHPUnit config
- Reviewing PHP for missing types, untyped arrays, stringly-typed code, service locators, or `Exception`-suffixed names
- Modernizing a PHP 7.x / early-8.x codebase toward 8.5 idioms

Do not use it for: Blade/Twig template markup with no PHP logic, or generated code you do not own.

## Core Defaults — apply unless the task gives a specific reason not to

### 1. `declare(strict_types=1)` on every file; one PSR-4 class per file

Strict mode turns silent scalar coercion into a visible `TypeError` and is what makes static analysis trustworthy. The
declaration only affects calls _originating in that file_, so it belongs on every file, not just entrypoints.

```php
<?php

declare(strict_types=1);

namespace App\Billing;
```

### 2. Type every boundary natively; use docblocks only for shapes and generics

Native parameter, return, and property types carry the contract — aim for 100% native coverage on public APIs. Use
`mixed` only at a genuine boundary (decoded input, third-party data) and narrow it immediately. A bare `array` type is
not enough information; annotate its shape.

```php
/** @return list<LineItem> */
public function lineItems(): array { /* ... */ }
```

See `references/types-and-strict-mode.md` for generics (`list<T>`, `array<K,V>`, `iterable<T>`, `class-string<T>`,
`non-empty-string`, `@template`) and the rule that generic docblocks repeat on the interface _and_ every implementation.

### 3. `final readonly class` for value objects; `final` for most domain classes; non-`final` for mockable services

Make inheritance and mutation opt-in. Value objects, DTOs, and events are `final readonly` because their equality must
not be subclassed and their state is captured once. Services stay **non-`final`** so PHPUnit can mock them — _except_
security-critical implementations (e.g. an HMAC signer, a password hasher), which are `final` but implement an interface
so tests mock the interface instead.

```php
final readonly class Money
{
    public function __construct(
        public string $currency,
        public int $minorUnits,
    ) {}
}
```

`final readonly class` is just sugar for marking every declared property `readonly`. A hooked (virtual) property
**cannot** be `readonly`, so a value object that legitimately needs **property hooks** (8.4) — and many do, for derived
accessors — must instead be a `final class` with `public readonly` on each _stored_ property, leaving the hooked
properties un-`readonly`. Prefer the class-level form; drop to per-property `readonly` only when hooks require it. See
`references/value-objects-and-immutability.md`.

### 4. Constructor property promotion by default

Promotion removes redundant boilerplate. Drop to a declared property assigned in the body only when the constructor
_derives_ or _coerces_ a value. Never declare and promote the same property.

### 5. Constructors are `public` and self-validating; normalize, then validate

Any construction path must yield a valid, canonical instance. Normalize a value _before_ validating it, in the
constructor body, so a direct `new` cannot bypass the rules. Constructors only initialize state — no I/O, no events, no
service calls (those belong in factories or services). Value objects never take injected dependencies.

### 6. Immutability via the wither pattern; on 8.5 use clone-with

Return a new instance rather than mutating. PHP 8.5's clone-with expression takes an **array of overrides** — note this
is the shipped syntax, not the brace-block form from earlier RFC drafts.

```php
public function withAlpha(int $alpha): self
{
    return clone($this, ['alpha' => $alpha]); // PHP 8.5
    // pre-8.5: return new self(red: $this->red, green: $this->green, blue: $this->blue, alpha: $alpha);
}
```

### 7. Enums for every closed set; back them only when the value crosses a boundary

Use a pure enum by default; add a backing type (prefer `string`) only when the value is persisted or transmitted (DB,
API, queue). Store display labels in attributes, never as the backed value — labels change, backed values cannot without
a migration. Enum methods stay pure. Use `from()` for trusted values (throws) and `tryFrom()` for untrusted input
(returns `null`).

```php
enum InvoiceStatus: string
{
    case Draft = 'draft';
    case Paid = 'paid';
}
```

### 8. Distinguish value objects from entities

Value objects are defined by their values: immutable (`final readonly`), self-validating, dependency-free, carrying
intrinsic invariants. Entities have identity and a mutable lifecycle and are **not** `readonly`. Extrinsic constraints
(uniqueness, "this email is already taken") live in the entity or persistence layer, never in the value object.

### 9. Named constructors use the `from()` / `tryFrom()` vocabulary

Mirror `BackedEnum`. The parameter _type_ communicates the input format — never encode it in the name (`from()`, not
`fromString()`). `make()` / `of()` are fine when they read naturally; use descriptive domain names for semantic
construction (`Invoice::draft()`). See `references/value-objects-and-immutability.md`.

### 10. `match` over `switch`; exhaustive over enums, throwing `default` on open types

`match` is an expression, strict (`===`), with no fall-through. Omit `default` when PHPStan can prove exhaustiveness
over
a backed enum. When matching open types (`string`, `int`), add a `default` that throws a **named domain exception**. For
logically impossible branches, call a `never`-returning helper (`UnreachableCode::reached($value)`) to enable narrowing.

### 11. Throw typed exceptions named after the problem — no `Exception` suffix

`NotFound`, `UnableToReadFile`, `InvalidTraceDepth` — not `NotFoundException` or `FileException`. Each package defines a
marker interface (`interface BillingException extends \Throwable {}`); concrete exceptions extend the correct SPL base
**and** implement the marker:

| Base                       | Use for                                                                       |
| -------------------------- | ----------------------------------------------------------------------------- |
| `LogicException`           | Programmer error, violated precondition — should never happen in correct code |
| `InvalidArgumentException` | A specific bad argument (a `LogicException` subtype)                          |
| `RuntimeException`         | I/O, network, "not found at runtime" — cannot be detected ahead of time       |

Exception constructors take **domain values**, not pre-formatted strings. Don't use exceptions for expected outcomes — a
missing record returns `null`, it does not throw. See `references/exceptions-and-control-flow.md`.

### 12. Model nullability honestly; encode it in method names

`null` means meaningful, acceptable absence — not "not set yet". `get*()` returns the value or throws; `find*()` returns
`T|null`; `has*()` / `is*()` / `can*()` return `bool`. Use `?->` and `??` for genuinely optional navigation, not to
paper over a broken data model. Avoid properties that are null only because they are assigned after construction —
inject at construction instead. Plain accessors are nouns (`message()`), not `getMessage()`.

### 13. Inject every dependency through the constructor — no service locator, no setter injection

Service wiring is explicit and readable. Domain code never references a PSR container, framework base classes, or
concrete I/O. Inject `LoggerInterface` with a `new NullLogger()` default rather than reaching for a `LoggerAwareTrait`.
See `references/architecture-and-di.md`.

### 14. Interfaces get the clean noun-name; implementations get a descriptive prefix

`EventDispatcher` (interface) → `DefaultEventDispatcher`, `NullEventDispatcher`, `CachingEventDispatcher`. No `I`
prefix,
no `Interface` suffix — the keyword already says so. Classes are nouns, never `Manager` / `Helper` / `Util`. Events are
past-tense (`OrderShipped`, no `Event` suffix). Prefer narrow, single-capability interfaces. **Exception:** never rename
PSR interfaces — reference `Psr\Log\LoggerInterface` by its canonical FQN.

### 15. Attributes are metadata only — resolve once, cache, never reflect in a hot path

Attributes describe what something _is_ (enum labels, ORM mapping, stability markers like `#[Internal]`). They must not
drive control flow or wire the container. Use `#[\Override]` (8.3+) when overriding to catch signature drift.
Implement `\JsonSerializable` explicitly for any serialized object — never rely on the default object cast — and add a
static `from(array $data)` for round-tripping. See `references/attributes-and-serialization.md`.

### 16. Collections are docblock-typed arrays by default; a class only when warranted

Express collections as `list<T>` / `array<K,V>` and accept `iterable<T>` on public params (so generators and lazy
collections work). Build a named collection class only for wide reuse, runtime element validation, or domain methods
beyond iteration. On 8.5, use the pipe operator `|>` and first-class callables (`trim(...)`) for analyzable single-value
pipelines instead of `call_user_func` or string callables.

```php
$slug = $title |> trim(...) |> strtolower(...); // PHP 8.5
```

## Quick Triage Table

| Situation                                      | Default choice                                                         |
| ---------------------------------------------- | ---------------------------------------------------------------------- |
| Modeling an immutable domain value             | `final readonly class`, self-validating, dependency-free               |
| Modeling a thing with identity and a lifecycle | Entity — a `final` (not `readonly`) class with typed properties        |
| Modeling a fixed set of values                 | Pure `enum`; back with `string` only if it crosses a boundary          |
| Constructing from a value                      | Named constructor `from()` (throws) / `tryFrom()` (null)               |
| Producing a changed copy                       | Wither returning `clone($this, [...])` (8.5) or `new self(...)`        |
| Branching on a value                           | `match` (exhaustive over enum, or throwing `default`)                  |
| Signaling an error                             | Throw a typed exception named after the problem                        |
| Expected "not found"                           | Return `T\|null` from a `find*()` method                               |
| A derived/computed property                    | Property hook (8.4) or a method — not a stored field                   |
| Restricting who may mutate a property          | Asymmetric visibility `public private(set)` (8.4) on an entity         |
| A dependency a class needs                     | Constructor injection of an **interface**                              |
| A single-value transform pipeline              | Pipe operator `\|>` + first-class callables (8.5)                      |
| A return value callers must not ignore         | `#[\NoDiscard]` (8.5)                                                  |
| Dates and times                                | `\DateTimeImmutable` in UTC; inject a `Clock`; convert at the boundary |

## Reference Files

Read the relevant file when the SKILL.md guidance leaves a judgment call open:

- `references/types-and-strict-mode.md` — `strict_types`, native types, deliberate union types, `mixed` at boundaries,
  type-coverage targets, docblock generics (`list`, `array`, `iterable`, `@template`, `class-string`,
  `non-empty-string`,
  `positive-int`), repeating annotations on interface + implementation.
- `references/value-objects-and-immutability.md` — VO vs entity, `final readonly class`, promotion vs declared/derived
  properties, constructor visibility, normalize-then-validate, named constructors (`from`/`tryFrom`/`make`), the wither
  pattern + 8.5 clone-with, `__toString`/`Stringable`, property hooks for derived values.
- `references/enums.md` — pure vs backed, string-over-int backing, labels in attributes, pure enum methods,
  `from`/`tryFrom`, `enum_values()`, enums vs class constants.
- `references/exceptions-and-control-flow.md` — naming after the problem, marker-interface hierarchy + SPL base table,
  exception constructors take domain values, exceptions are not flow control, `match` over `switch`, exhaustiveness +
  `UnreachableCode`/`never`, guard clauses, the `get`/`find`/`has`/`is`/`can` method vocabulary.
- `references/architecture-and-di.md` — layered Domain/Application/Infrastructure with inward-only dependencies,
  constructor-injection-only, interface naming (clean noun + prefixed implementations), the `final` policy, thin
  entrypoints, PSR interface usage and canonical naming.
- `references/attributes-and-serialization.md` — attributes as metadata only, resolve-and-cache, `#[\Override]`,
  stability markers, `JsonSerializable` always, bidirectional `from(array)` + hydrators, Doctrine entity mapping.
- `references/datetime-and-boundaries.md` — `\DateTimeImmutable` only, accept `\DateTimeInterface` and coerce, UTC as
  the
  application timezone, conversion at the request boundary, RFC 3339 vs Unix timestamp, the injected `Clock`, request
  vs domain validation.
- `references/php85-features.md` — pipe operator `|>`, clone-with (array form), `#[\NoDiscard]`, `array_first`/
  `array_last`, `#[\Override]` on properties, property hooks (8.4), asymmetric visibility (8.4), `new` without
  parentheses (8.4), lazy objects (8.4), and version-constraint policy.
- `references/tooling-and-testing.md` — PHPStan `level: max` (no `@phpstan-ignore`, no growing baseline), PHPUnit
  (`final` test classes, `static` data providers, mock interfaces not concretes, assert exception _type_ not message,
  real value objects), the project's coding-standards tool (Pint / PHP_CodeSniffer / PHP-CS-Fixer), Rector dry-run in
  CI, Composer policy, the CI pipeline.
- `references/application-patterns.md` — PSR-15 middleware + PSR-7 immutability, RFC 7807 problem-details errors, PSR-3
  structured logging (no interpolation), PSR-16 caching as a decorator, message bus, repositories, domain events,
  dispatched side effects, cursor pagination with capped limits.

## Common Mistakes (and the fix)

| Mistake                                                           | Fix                                                                                        |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `@phpstan-ignore` to silence a finding                            | Fix the type; only ignore a confirmed tool/stub bug, with a linked issue                   |
| `mixed` everywhere / bare `array` returns                         | Native types + `@return list<T>` / `array<K,V>`; narrow `mixed` at the boundary            |
| Returning `false` / `null` / a magic string for a real error      | Throw a typed exception named after the problem                                            |
| `FileException`, `MyException` (category names + suffix)          | Name the problem (`UnableToReadFile`); extend the right SPL base + marker                  |
| Magic strings for a closed set; `switch` ladders                  | Backed enum + `match` (omit `default` when exhaustive)                                     |
| `final` on a service class                                        | Leave services non-`final`; mock the interface; `final` only security-critical impls       |
| Constructor side effects (I/O, events, lookups)                   | Constructors initialize state only; side effects go in factories/services                  |
| Normalizing only inside `from()`                                  | Normalize in the constructor body so direct `new` cannot bypass it                         |
| Relying on the default object-to-JSON cast                        | Implement `\JsonSerializable`; add static `from(array)` to round-trip                      |
| `getMessage()` for a plain accessor                               | `message()`; reserve `get*()` for retrieval that may throw                                 |
| `\DateTime` property/return type; `new \DateTime($untrusted)`     | `\DateTimeImmutable`; `createFromFormat` with an explicit format; UTC + Clock              |
| Autowiring / service locator / setter injection                   | Explicit constructor injection of interfaces only                                          |
| `call_user_func`, string callables, `count()` in a loop condition | First-class callables `fn(...)`, the `\|>` pipe, `foreach` over `iterable`                 |
| `^8.5` caret + polyfills + `PHP_VERSION_ID` runtime branching     | Explicit version union (`8.4.* \|\| 8.5.*`); raise the floor; use features unconditionally |

## Modernization Order for an Existing Codebase

Do not flip everything at once:

1. Add CI scripts: `phpstan`, the coding-standards check (the project's Pint / `phpcs` / `php-cs-fixer`), `phpunit`,
   `composer validate --strict`, `composer audit`.
2. Add `declare(strict_types=1)` to every file; fix the coercion errors that surface.
3. Raise PHPStan one level at a time toward `level: max`; commit a baseline only to ratchet legacy debt downward.
4. Add native types to every signature and property; replace bare `array` with docblock generics.
5. Convert class constants representing closed sets to backed enums; replace `switch` with `match`.
6. Make value objects `final readonly`, add named constructors, replace setters with withers.
7. Rename `*Exception` classes after their problem; introduce per-package marker interfaces.
8. Replace service locators / static singletons with constructor injection.
9. Adopt 8.5 features where they improve clarity (clone-with, `|>`, `#[\NoDiscard]`, property hooks).

## Pre-Commit Self-Check

Before saying "done" on a PHP change, verify:

- [ ] Every file opens with `declare(strict_types=1)`, has a PSR-4 namespace, one class per file.
- [ ] All parameters, returns, and properties are natively typed; no unjustified `mixed`; every `array` API has a
      `list<>` / `array<>` docblock repeated on the interface **and** implementation.
- [ ] Value objects / DTOs / events are `final readonly`, self-validating, dependency-free.
- [ ] Services are non-`final` and depend on injected interfaces — no `new` of a concrete dependency, no service
      locator.
- [ ] Closed sets are enums (string-backed only when they cross a boundary); branching uses `match`.
- [ ] Errors throw typed exceptions named after the problem (right SPL base + package marker); expected absence returns
      `null`. No constructor side effects.
- [ ] `null` is modeled honestly; method names follow the `get`/`find`/`has`/`is`/`can` vocabulary.
- [ ] Dates are `\DateTimeImmutable` in UTC with an injected `Clock`; `\JsonSerializable` is implemented on serialized
      objects.
- [ ] PHP 8.5/8.4 features are used only where they aid clarity (clone-with via `clone($o, [...])`, `|>`,
      `#[\Override]`,
      property hooks for derived values) — not decoratively.
- [ ] `phpstan analyse` is green at `level: max` with **zero** new ignores or baseline growth; the project's
      coding-standards tool is clean; PHPUnit passes (mocking interfaces, asserting exception types, using real value
      objects).
