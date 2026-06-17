# Validation — The Request Boundary

Every byte that enters the service from outside the type system is `unknown` until a schema proves otherwise: JSON
bodies, query strings, path params, headers. Validation is where a claim ("this is a `CreateTaskInput`") becomes a fact.
Do it once, at the edge, with a schema — and make the schema match the OpenAPI contract exactly, including its
`additionalProperties: false`.

## Default to Zod with a one-line pipe

A `PipeTransform` that runs a schema is all the glue NestJS needs. A thrown `ZodError` is caught by the global filter
and rendered as the validation envelope (see `references/errors.md`).

```ts
import { type PipeTransform } from "@nestjs/common";
import { type ZodType } from "zod";

export class ZodValidationPipe<T> implements PipeTransform<unknown, T> {
    constructor(private readonly schema: ZodType<T>) {}
    transform(value: unknown): T {
        return this.schema.parse(value);
    }
}
```

Apply it per argument so each operation validates against its own schema:

```ts
@Post()
@HttpCode(201)
async create(@Body(new ZodValidationPipe(createTaskSchema)) body: CreateTaskInput) { … }
```

The inferred type comes from the schema, so the static type and the runtime check can never disagree:

```ts
export const createTaskSchema = z.strictObject({
    title: z.string().min(1),
    notes: z.string().nullable().optional(),
    state: z.enum(["actionable", "backlogged"]).optional(),
    projectIds: z.array(z.string()).optional(),
    startDate: z.string().nullable().optional(),
    dueDate: z.string().nullable().optional(),
});
export type CreateTaskInput = z.infer<typeof createTaskSchema>;
```

## `strictObject` to mirror `additionalProperties: false`

The contract's request schemas almost always say `additionalProperties: false`. Match it with `z.strictObject(...)` (or
`.strict()`), which **rejects unknown keys** instead of silently dropping them. A client that sends a misspelled or
disallowed field gets a 422, exactly as the contract promises — this is also what the conformance fuzzer checks.

```ts
z.strictObject({ … }) // unknown key → ZodError → 422 validation_failed
z.object({ … })       // unknown key → silently stripped → contract violation
```

## `minProperties` and "at least one field"

A `PATCH` that edits a subset (`title` and/or `notes`) must reject an empty body (the contract's `minProperties: 1`).
Express it with a refinement:

```ts
export const patchTaskSchema = z
    .strictObject({
        title: z.string().min(1).optional(),
        notes: z.string().nullable().optional(),
    })
    .refine((obj) => Object.keys(obj).length > 0, {
        message: "at least one field is required",
    });
```

## Absent vs null vs present — the three states, kept distinct

This is the subtlety that trips up partial updates. Three states must stay separable:

| Wire                  | Meaning           | Zod           | TS type          |
| --------------------- | ----------------- | ------------- | ---------------- |
| key omitted           | leave unchanged   | `.optional()` | `T \| undefined` |
| `"dueDate": null`     | clear the value   | `.nullable()` | `T \| null`      |
| `"dueDate": "2026-…"` | set to this value | (base schema) | `T`              |

So a reschedule field that may be omitted (leave) **or** explicitly nulled (clear) **or** set is
`z.string().nullable().optional()` → `string | null | undefined`. Do **not** collapse these. The domain resolves them
against current state at decide-time (see `references/domain-core.md`): `undefined` → keep prior, `null` → clear, value
→ set. Collapsing `undefined` and `null` makes "I didn't mention dueDate" indistinguishable from "clear dueDate", which
silently wipes data.

A small `Patch<T>` helper carries the distinction into the domain without leaking `undefined` everywhere:

```ts
export type Patch<T> =
    | { readonly set: false }
    | { readonly set: true; readonly value: T };

export function toPatch<T>(value: T | undefined): Patch<T> {
    return value === undefined ? { set: false } : { set: true, value };
}
```

## Coercing query parameters

Query values are always strings. Coerce booleans and numbers in the schema, with the contract's default:

```ts
export const queryBool = z
    .union([
        z.literal("true"),
        z.literal("false"),
        z.literal("1"),
        z.literal("0"),
    ])
    .optional()
    .transform((v) => v === "true" || v === "1")
    .default(false);

export const limit = z.coerce.number().int().min(1).max(100).default(20);
```

Use `z.object` (not `strictObject`) for query schemas — query strings legitimately carry extra keys (pagination,
tracing) you don't want to 422 on. Bodies are strict; queries are lenient.

## Where format validation belongs — and where it doesn't

Distinguish **shape** validation (is this a string? is the key allowed?) from **semantic** validation (is this a valid
`YYYY-MM-DD`? is `startDate <= dueDate`?).

- **Shape** belongs in the Zod schema at the boundary. Keep it to structural checks plus cheap constraints (`min(1)`,
  `enum`).
- **Semantic / cross-field** validation belongs in the **domain** (`decide`), for two reasons: the error's `field` and
  `reason` then come from one place (the domain `ValidationError`), and cross-field rules (`startDate <= dueDate`) often
  need the _resolved_ values (after merging a partial update against current state), which the boundary doesn't have.

Concretely: validate `dueDate` is a string at the edge; check `startDate <= dueDate` in `decide`, throwing a
`ValidationError("…", "dueDate")` that the filter maps to `422` with `details.field = "dueDate"`. Keeping date-string
_parsing_ in the domain (`parseIsoDate`) also means one canonical parser, not a Zod regex that drifts from it.

This division keeps the boundary schema a faithful mirror of the OpenAPI request schema (so the emitted-≡-canonical test
and the fuzzer stay honest) while the genuinely domain rules live with the domain.

## The class-validator alternative

If you choose `class-validator` + `class-transformer` instead of Zod (e.g. to feed `@nestjs/swagger` from the same DTOs),
the discipline is identical — only the mechanism changes:

```ts
export class CreateTaskDto {
    @IsString() @MinLength(1) title!: string;
    @IsOptional() @IsString() notes?: string | null;
}
```

Enable the built-in pipe globally with `whitelist: true` + `forbidNonWhitelisted: true` (the `strictObject` equivalent —
unknown keys 422) and `transform: true`:

```ts
app.useGlobalPipes(
    new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
    }),
);
```

Trade-off: decorator DTOs integrate with Swagger decorators for free but are less composable than Zod schemas and give
you no `z.infer` single-source-of-truth. Pick **one** validation strategy for the whole service; don't mix.
