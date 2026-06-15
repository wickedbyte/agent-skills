# Tooling and Testing

PHPStan at `level: max`, PHPUnit conventions, the project's coding-standards tool, Rector dry-run, the Composer
policy, and the CI pipeline order.

## PHPStan at `level: max`

Run PHPStan at the maximum level over **both** `src` and `tests`. Greenfield projects start at `max` and stay there;
the level is never lowered to hide findings — findings are fixed.

```neon
# phpstan.neon
parameters:
    level: max
    paths:
        - src
        - tests
```

**No `@phpstan-ignore`.** An inline suppression is not a resolution; if PHPStan reports something, the code is wrong
and gets fixed. The only acceptable ignore is a _confirmed_ PHPStan bug or a wrong third-party stub — and then it
carries a comment linking the upstream issue so it can be removed when fixed.

```php
// ❌ Suppressing the finding instead of fixing the type
/** @phpstan-ignore-next-line */
$result = $this->doSomethingUntyped();

// ✅ Fix the underlying type problem so the analyzer can prove it
```

**Baselines ratchet legacy debt to zero — never growing.** A `phpstan-baseline.neon` is a _backlog_ for a legacy
migration: it is reduced over time and deleted when empty. Committing a baseline on a greenfield project is an
anti-pattern — it bakes in a floor of unresolved issues from day one. A PR may shrink the baseline; it must never grow
it.

Generic docblocks repeat on the **interface and every implementation** — never rely on inheritance to propagate them.
PHPStan resolves types against the declared interface, so an unannotated implementation loses element types for
callers, and an annotation only on the implementation is invisible to callers holding the interface. An implementation
may legitimately narrow (`@return iterable<InMemoryTombstone>` against the interface's `@return iterable<Tombstone>`);
PHPStan enforces the subtype relationship.

## PHPUnit — default, not Pest

All tests are PHPUnit. **Pest is not used:** it abuses closure binding to inject state into callables, obscuring the
PHPUnit primitives it depends on. A wrapper that adds magic over an explicit, already-mandatory tool is not an
improvement.

```php
final class OrderIdTest extends TestCase
{
    public function test_from_creates_valid_instance(): void { /* ... */ }
}
```

Conventions:

- **`final` test classes extending `TestCase`.** Test classes are never extended.
- **Data providers are `public static`.** Array keys are human-readable case labels in failure output (describe the
  scenario, not the value). Use a provider instead of duplicating near-identical test methods.
- **Mock interfaces, never concretes.** `$this->createMock(Mailer::class)` against the interface enforces that the
  code under test depends only on the contract. Mocking `SmtpMailer` ties the test to the implementation (and a `final`
  service cannot be doubled at all — see the `final` policy).
- **`createStub` vs `createMock`.** Use `createStub` when the double only needs to return a value (no interaction
  assertion). Use `createMock` when asserting a method _is_ called — e.g. that a service dispatched an event:

    ```php
    $dispatcher = $this->createMock(EventDispatcherInterface::class);
    $dispatcher->expects($this->once())
        ->method('dispatch')
        ->with($this->isInstanceOf(OrderProcessed::class));
    ```

- **Assert the exception _type_, not the message.** Messages are for humans and may change for clarity without a
  behavior change; coupling a test to a string couples it to nothing behavioral. If the same type is thrown from
  several distinct conditions callers must tell apart, add narrower types.

    ```php
    // ✅ Type identifies the error path
    $this->expectException(InvalidTraceDepth::class);
    $config->withTraceDepth(-1);

    // ❌ Message is unstable, not behavioral
    $this->expectExceptionMessage('Trace depth must be between 1 and 100');
    ```

    The exception is when the exception carries testable _state_ (an HTTP status, a `toResponse()`); asserting on that
    state is fine.

- **Use real value objects — never mock them.** Construct `OrderId::from('ord-123')`. Mocking a value object signals
  it is hard to construct, which is itself a design smell to fix.

### Integration tests against real infrastructure

Integration tests verify behavior crossing a system boundary (database, bus, cache). Doubling the infrastructure
boundary defeats the point. In-memory SQLite is a fine _starting point_ for small apps, but it is not a valid proxy
once you rely on engine-specific features (`RETURNING`, `ON CONFLICT`, JSON operators, `TIMESTAMPTZ`); then run against
a real instance of the **same engine and major version** as production, migrated and seeded from a deterministic,
version-controlled test seed (the same seed used for dev environments). Isolate tests with a per-test transaction
rolled back in `tearDown` (fast), or a truncate-and-reseed when the code under test commits internally. Integration
tests verify the infrastructure wires up — they are **not** where domain logic is verified (that is fast unit tests).

### Fixtures favor isolation over DRY

Test code is not held to production DRY standards: a slightly repetitive but self-contained test beats a terse one
coupled to shared state. If two tests break when one fixture method changes, the fixture does too much. Express shared
setup as `private static` factory methods on the test class (using default-parameter expressions for variants); promote
canonical values (a fixed `OrderId`, a known email) to a `Tests\Fixtures\*` class only when reused widely. Never share
mutable state across methods or depend on execution order — re-initialize per test in `setUp()`. Traits in tests are
for shared _behavior_ (custom assertions), not fixtures.

## Coding standards — follow the project's existing tool

**Which formatter to use is a project decision; do not change it.** A codebase has at most one coding-standards tool,
and it is whatever the project already committed:

- **Laravel Pint** (`pint.json`) — common in Laravel projects; an opinionated PHP-CS-Fixer wrapper.
- **PHP_CodeSniffer** (`phpcs.xml` / `phpcs.xml.dist`) — `phpcs` to check, `phpcbf` to fix; common in WordPress and
  many library codebases.
- **PHP-CS-Fixer** (`.php-cs-fixer.php` / `.php-cs-fixer.dist.php`) — widely used standalone.

If the project already has one of these, run **it** (and match its configured ruleset) — don't introduce a second tool
or rewrite the config to a different standard. Only when a project has **no** coding-standards tooling at all should you
default to introducing PHP-CS-Fixer (added via a Composer dev dependency / shim) with a PER-CS baseline. PER-CS is the
current PHP-FIG style standard (it supersedes PSR-12); a reasonable starting `.php-cs-fixer.php` is:

```php
return (new PhpCsFixer\Config())
    ->setRiskyAllowed(false)
    ->setRules([
        '@PER-CS' => true,
        'declare_strict_types' => true,
        'no_unused_imports' => true,
        'ordered_imports' => true,
        'array_syntax' => ['syntax' => 'short'],
        'trailing_comma_in_multiline' => ['elements' => ['arrays', 'arguments', 'parameters']],
    ])
    ->setFinder(
        PhpCsFixer\Finder::create()->in([__DIR__ . '/src', __DIR__ . '/tests']),
    );
```

Whatever the tool, the principles are the same: `strict_types` declared, imports ordered and unused ones removed, short
array syntax, trailing commas in multiline constructs. Run the checker in CI in check-only mode.

## Rector — dry-run in CI, applied locally

`rector.php` is committed and defines the PHP target and rule sets. Rector runs **`--dry-run` in CI**: it _reports_
unmodernized code but never rewrites it in the pipeline. Developers apply changes locally and commit them
intentionally, because Rector edits span many files and deserve review.

```bash
vendor/bin/rector --dry-run   # CI: report only, exit non-zero on findings
vendor/bin/rector             # local: apply and review
```

## Composer policy

- Require an explicit PHP version (raise the floor; avoid loose carets where the project pins a version union).
- **Commit `composer.lock` for applications**; keep dev tooling in `require-dev`.
- `composer validate --strict` and `composer audit` run in CI.
- Allow-list plugins **explicitly** under `config.allow-plugins` (no blanket enable).
- Build production with an **optimized autoloader** (`composer dump-autoload -o` / `--optimize-autoloader --no-dev`).

```json
{
    "config": {
        "sort-packages": true,
        "allow-plugins": {
            "phpstan/extension-installer": true
        }
    }
}
```

## CI pipeline order

Run cheap, fail-fast checks first; the suite is only mergeable when every stage exits 0:

```
1. composer validate --strict   # manifest sanity
2. composer audit               # known-vulnerable dependencies
3. coding-standards check       # the project's tool: pint --test / phpcs / php-cs-fixer --dry-run
4. phpstan analyse              # level: max, zero new ignores / no baseline growth
5. rector --dry-run             # report-only modernization gate
6. phpunit                      # unit + integration
```

Also worth wiring in: **Infection** (mutation testing) to measure whether tests actually catch regressions — a high
line-coverage suite with a low mutation score is testing the wrong thing — and **PHPBench** for repeatable benchmark
harnesses on hot paths (a controlled measurement tool, not a production profiler).
