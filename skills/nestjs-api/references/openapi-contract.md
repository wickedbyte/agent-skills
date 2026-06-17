# OpenAPI Conformance

The OpenAPI document is the wire contract, and contract-correctness is proven two ways that must **both** pass:

1. **Emitted ≡ canonical** — an in-repo test asserts the document the service *serves* at `/openapi.json` equals the
   frozen `openapi.yaml`.
2. **Running server conforms** — an external, property-based fuzzer (Schemathesis) drives the live container against the
   spec and checks every request/response against the schemas.

Passing both means the contract describes the code and the code obeys the contract. Passing only `tsc` means neither.

## Two strategies for the emitted document

### Strategy A — embed and serve the canonical document (preferred when the contract is frozen)

When `openapi.yaml` is authored first and frozen, the lowest-risk path is to **serve it verbatim**: a build step reads
the canonical YAML and emits it as a typed module the meta controller returns. The emitted document then equals the
canonical *by construction* — there is no generator to tune — and a drift check keeps the embedded copy honest.

```ts
// openapi.document.ts — GENERATED from ../openapi.yaml by scripts/sync-openapi.mjs — do not edit.
export const openapiDocument: Record<string, unknown> = { /* the full OpenAPI 3.1 doc */ };
```

```ts
@Controller()
export class OpenapiController {
    @Get("openapi.json")
    getOpenapi(): Record<string, unknown> {
        return openapiDocument;
    }
}
```

The sync script (run by `make openapi-sync`) parses the YAML and writes the module; CI fails if the committed module
drifts from the source:

```
make openapi-sync
git diff --exit-code -- src/openapi.document.ts || { echo "openapi.document.ts drifted — run make openapi-sync"; exit 1; }
```

This trades "the doc is generated from my decorators" for "the doc is exactly the contract" — the right trade when the
contract is the source of truth and you'd otherwise spend hours making a generator reproduce someone else's YAML byte
for byte.

### Strategy B — generate from your schemas (preferred when you own the contract)

When the service *defines* the API, generate the document from the same schemas you validate with, so the doc can't
drift from the code. With `@nestjs/swagger`:

```ts
const config = new DocumentBuilder()
    .setTitle("Taskflow API").setVersion("1.0.0")
    .addBearerAuth({ type: "http", scheme: "bearer", bearerFormat: "JWT" }, "oidcBearer")
    .build();
const document = SwaggerModule.createDocument(app, config);
```

If you validate with Zod, bridge it (e.g. `nestjs-zod`, which turns a Zod schema into a Swagger-visible DTO so one
schema feeds validation, the static type, **and** the OpenAPI). If you validate with class-validator, the
`@nestjs/swagger` CLI plugin reads the DTO decorators directly. Either way:

- Use **strict** schemas so generated request bodies carry `additionalProperties: false`.
- Pin response envelopes explicitly (`@ApiOkResponse({ type: TaskEnvelope })`) so the wrapper shapes match.
- Then assert the generated document equals the canonical one (below). Expect to spend real time reconciling
  nullability, `format`, defaults, and `additionalProperties` — this reconciliation **is** the work in strategy B, and
  it is why strategy A wins for a frozen external contract.

## The emitted ≡ canonical test

Parse the canonical YAML, compare it to the served document with a deep equality, and also drive it over HTTP so you
test the actual wire output, not just the in-memory object:

```ts
import { parse } from "yaml";
import { readFileSync } from "node:fs";

const canonical = parse(readFileSync(resolve(here, "../../../openapi.yaml"), "utf8")) as Record<string, unknown>;

describe("OpenAPI contract (emitted ≡ canonical)", () => {
    it("the served document equals the canonical openapi.yaml", () => {
        expect(openapiDocument).toEqual(canonical);
    });

    it("GET /openapi.json returns the canonical document", async () => {
        const res = await request(app.getHttpServer()).get("/openapi.json");
        expect(res.status).toBe(200);
        expect(res.body).toEqual(canonical);
    });
});
```

For strategy B, normalize before comparing — both sides through a canonical JSON form (sorted keys, `$ref`s resolved or
both left unresolved, servers/examples stripped if they're not contractually meaningful). A semantic-equality helper
beats brittle string matching. For strategy A, the documents are identical so a plain `toEqual` suffices.

## The /openapi.json endpoint is always open

It is a meta endpoint: no auth, available even when `AUTH_REQUIRED=true`, so doc tooling and the fuzzer can read it (see
`references/auth-oauth2.md`).

## External conformance — Schemathesis against the running container

The in-repo test proves the *document* is right; the fuzzer proves the *server* obeys it. Schemathesis reads the spec,
generates property-based requests for every operation, and asserts responses conform — status codes present in the
spec, response bodies matching the response schemas, `additionalProperties: false` honored, required fields present.

```bash
st run openapi.yaml --url http://localhost:8080
```

Run it against the booted container (via `compose`), not a mock. It catches the things unit tests miss: an endpoint that
returns a field not in the schema, a 500 on an input the spec says is valid, a missing required property, a status code
the spec doesn't declare. A common, *correct* outcome to understand: a fuzzer run against a **non-persistent mock** will
exercise schemas but can't satisfy stateful flows — that's expected, and it's why stateful conformance also needs the
behavioral scenario tests (the invariant suite in `references/testing.md`), not just schema fuzzing.

## Keeping the boundary schemas honest

The emitted document and the fuzzer both assume your **request schemas mirror the contract**. The two failure modes:

- A request schema that's **looser** than the contract (e.g. `z.object` instead of `z.strictObject`) → the server
  accepts inputs the contract forbids → the fuzzer's negative cases fail.
- A response serializer that adds or omits a field → the fuzzer's response-schema check fails.

Treat a fuzzer failure as a contract violation to fix in the code (or, rarely, a genuine finding about the contract to
raise) — never as a reason to loosen the spec.
