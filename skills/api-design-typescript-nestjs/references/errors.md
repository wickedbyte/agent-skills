# Errors — One Envelope, One Filter

Every error the API can produce leaves through a single shape and a single place. Domain code throws **named** errors
that describe the problem; one global `@Catch()` filter is the only code that knows HTTP status codes and renders the
contract's error envelope. This keeps controllers free of `try/catch`, keeps status-code policy in one auditable spot,
and guarantees no raw stack trace or framework-default error body ever reaches a client.

## The envelope

The contract's error shape (one `error` object, a `code`, a `message`, optional free-form `details`):

```json
{
    "error": {
        "code": "validation_failed",
        "message": "dueDate must be on or after startDate",
        "details": {
            "field": "dueDate",
            "reason": "dueDate must be on or after startDate"
        }
    }
}
```

```ts
export type ErrorCode =
    | "validation_failed"
    | "not_found"
    | "conflict"
    | "invalid_state_transition"
    | "internal_error";

export interface ErrorEnvelope {
    readonly error: {
        readonly code: ErrorCode;
        readonly message: string;
        readonly details?: Record<string, unknown>;
    };
}

export function buildEnvelope(
    code: ErrorCode,
    message: string,
    details?: Record<string, unknown>,
): ErrorEnvelope {
    return details === undefined
        ? { error: { code, message } }
        : { error: { code, message, details } };
}

export function fieldDetails(
    field: string | null,
    reason: string,
): Record<string, unknown> {
    return field === null ? { reason } : { field, reason };
}
```

`omit details when undefined` matters under `exactOptionalPropertyTypes` and keeps the body matching the contract's
`additionalProperties: false` (no `details: undefined` key serialized).

## The code → status table

The mapping is fixed by the contract. Note that **two** distinct domain conditions share 409:

| Domain condition                            | `code`                     | status |
| ------------------------------------------- | -------------------------- | ------ |
| Boundary/semantic validation failed         | `validation_failed`        | 422    |
| Resource not found                          | `not_found`                | 404    |
| Slug/uniqueness clash, stale-version append | `conflict`                 | 409    |
| Command issued against a terminal state     | `invalid_state_transition` | 409    |
| Anything unhandled                          | `internal_error`           | 500    |

Validation is **422**, not 400. Both `conflict` and `invalid_state_transition` are **409** but carry different `code`s —
the optimistic-concurrency clash and the terminal-state rejection must remain distinguishable to a client even though
the status is identical.

## Named domain errors

The domain throws errors named after the **problem**, carrying just enough structure for the filter to build `details`.
They live in `domain/errors.ts` (pure) and `store/errors.ts` (persistence) — neither imports `@nestjs/*`:

```ts
export class ValidationError extends Error {
    constructor(
        message: string,
        readonly field: string | null = null,
    ) {
        super(message);
    }
}
export class StateTransitionError extends Error {} // → 409 invalid_state_transition
export class VersionConflictError extends Error {} // → 409 conflict (I18 optimistic concurrency)
export class SlugConflictError extends Error {} // → 409 conflict, details.field = "slug"
export class NotFoundError extends Error {} // → 404 not_found
```

Throwing is correct for these because they unwind the command from anywhere in the stack (a guard deep in `decide`, a
unique violation in the store) straight to the filter, with no plumbing in between. (For _expected, in-band_ outcomes
that aren't errors — an empty list, an idempotent no-op — return a value, don't throw.)

## The global exception filter

A single `@Catch()` (no argument = catch everything) translates each known error to `{ status, body }` and falls back
to a logged 500 for the unknown. Register it once with `APP_FILTER`.

```ts
@Catch()
export class DomainExceptionFilter implements ExceptionFilter {
    private readonly logger = new Logger(DomainExceptionFilter.name);

    catch(exception: unknown, host: ArgumentsHost): void {
        const reply = host.switchToHttp().getResponse<FastifyReply>();
        const { status, body } = this.translate(exception);
        void reply.status(status).send(body);
    }

    private translate(exception: unknown): {
        status: number;
        body: ErrorEnvelope;
    } {
        if (exception instanceof ZodError) {
            const issue = exception.issues[0];
            const field = issue?.path.at(-1);
            const message = issue?.message ?? "validation failed";
            return {
                status: 422,
                body: buildEnvelope(
                    "validation_failed",
                    message,
                    fieldDetails(
                        field === undefined ? null : String(field),
                        message,
                    ),
                ),
            };
        }
        if (exception instanceof ValidationError) {
            return {
                status: 422,
                body: buildEnvelope(
                    "validation_failed",
                    exception.message,
                    fieldDetails(exception.field, exception.message),
                ),
            };
        }
        if (exception instanceof StateTransitionError) {
            return {
                status: 409,
                body: buildEnvelope(
                    "invalid_state_transition",
                    exception.message,
                ),
            };
        }
        if (exception instanceof VersionConflictError) {
            return {
                status: 409,
                body: buildEnvelope(
                    "conflict",
                    "the resource was modified concurrently",
                ),
            };
        }
        if (exception instanceof SlugConflictError) {
            return {
                status: 409,
                body: buildEnvelope("conflict", "slug already exists", {
                    field: "slug",
                }),
            };
        }
        if (exception instanceof NotFoundError) {
            return {
                status: 404,
                body: buildEnvelope("not_found", exception.message),
            };
        }
        if (exception instanceof HttpException) {
            const status = exception.getStatus();
            return {
                status,
                body: buildEnvelope(codeForStatus(status), exception.message),
            };
        }
        this.logger.error(
            "unhandled exception",
            exception instanceof Error ? exception.stack : exception,
        );
        return {
            status: 500,
            body: buildEnvelope("internal_error", "internal server error"),
        };
    }
}
```

Why it is shaped this way:

- **`ZodError` first.** Boundary validation failures arrive as `ZodError`; extract the first issue's last path segment
  as `field` and its message as `reason` so a 422 always points at the offending field, exactly as the contract's
  `details` promises.
- **Order from specific to general.** Domain errors, then the framework's `HttpException`, then the catch-all 500. An
  earlier, more specific arm wins.
- **The 500 arm logs and hides.** Log the stack server-side; return a generic `internal_error` message. Never leak an
  exception message, stack, or SQL error text to the client — those are an information-disclosure risk and aren't in the
  contract.
- **`@Catch()` with no argument** catches _everything_, including errors thrown inside pipes (your `ZodValidationPipe`)
  and guards, so validation and auth failures render through the same envelope.

## A note on framework defaults

Without this filter, Nest renders its own `{ statusCode, message, error }` shape — which is **not** the contract
envelope and will fail conformance. Registering the global filter is what makes every error path, including ones you
didn't anticipate, conform. Add a functional test per error code (422/404/409×2/500) asserting both the status and
`body.error.code`.
