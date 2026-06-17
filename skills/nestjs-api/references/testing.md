# Testing — Four Layers, Driven by Invariants

Tests are written **first**, from the contract's invariants, then the code is made to pass them. The suite has four
layers, each with a distinct job and speed. The cheap layers carry most of the weight; the expensive ones prove the
wiring. Map every invariant to at least one test name and keep that checklist current.

| Layer           | Scope                                  | Speed  | Tooling                                   |
| --------------- | -------------------------------------- | ------ | ----------------------------------------- |
| **Unit**        | pure domain (`decide`/`apply`/views)   | µs–ms  | Vitest, no IO                             |
| **Integration** | the store + migrations                 | s      | Vitest + Testcontainers (real Postgres)   |
| **Functional**  | HTTP through the booted app            | s      | Vitest + supertest (+ Testcontainers)     |
| **Contract**    | emitted ≡ canonical OpenAPI            | ms     | Vitest + `yaml`                           |

## Vitest with decorator metadata

NestJS DI needs decorator metadata at test time; Vitest's default transform doesn't emit it. Configure `unplugin-swc`
(see `references/toolchain.md`) or every `Test.createTestingModule(...)` fails to resolve providers. Use `globals: true`
and a generous `testTimeout` because Testcontainers can pull an image on first run.

## Unit tests — the bulk of the suite

Pure functions test exhaustively and instantly. Drive each from an invariant; use `it.each` for table-driven cases.

```ts
const NOW = new Date("2026-06-15T12:00:00Z");

describe("decideTask", () => {
    it("I1: empty title → ValidationError on 'title'", () => {
        expect(() => decideTask(emptyTask(), capture({ title: "" }), NOW))
            .toThrowError(expect.objectContaining({ field: "title" }));
    });

    it("I6: a completed task rejects :backlog with StateTransitionError", () => {
        const completed = foldTask(streamFor("complete"));
        expect(() => decideTask(completed, { kind: "backlog" }, NOW)).toThrow(StateTransitionError);
    });

    it.each<TaskState>(["actionable", "backlogged"])("capture allows %s", (state) => {
        expect(decideTask(emptyTask(), capture({ state }), NOW)[0]).toMatchObject({ state });
    });
});
```

Cover `apply`/`fold` (replay a stream, assert the aggregate), the colon splitter, date parsing, view predicates, and the
SSE name mapping here. None of these need a server or a database.

## Integration tests — the store against a real Postgres

Mocks hide exactly the bugs this layer exists to catch (constraint violations, transaction atomicity, concurrency). Use
Testcontainers to spin a real Postgres 17, migrate, and exercise the store.

```ts
let container: StartedPostgreSqlContainer;
let store: EventStore;

beforeAll(async () => {
    container = await new PostgreSqlContainer("postgres:17-alpine").start();
    const db = createDb(createPool(container.getConnectionUri()));
    await migrateToLatest(db);
    store = new EventStore(db);
}, 120_000);

afterAll(async () => { await container.stop(); });

it("I18: a stale-version append raises VersionConflictError", async () => {
    const { id, state } = await captureTask();
    await store.commitTask(id, state, [{ type: "TaskCompleted", completedAt: iso(NOW) }], NOW);
    await expect(store.commitTask(id, state, [{ type: "TaskCancelled", cancelledAt: iso(NOW) }], NOW))
        .rejects.toThrow(VersionConflictError); // same base version → unique violation
});

it("I19: the projection reflects the command before the call returns", async () => {
    const { id } = await captureTask();
    const row = await db.selectFrom("task_projection").selectAll().where("id", "=", id).executeTakeFirst();
    expect(row).toMatchObject({ id, state: "actionable", version: 1 });
});
```

Also test migrate up/down is clean, the seed is idempotent (run it twice → one Inbox), and truncate-then-`rebuild`
reproduces projections byte-for-byte.

## Functional tests — HTTP through the booted app

Boot the real `AppModule` on a Testcontainers Postgres and drive it with `supertest`. This proves routing, pipes, the
exception filter, and serialization together. A shared helper keeps each spec terse:

```ts
export async function createTestApp(env: Record<string, string> = {}): Promise<TestApp> {
    const container = await new PostgreSqlContainer("postgres:17-alpine").start();
    process.env.DATABASE_URL = container.getConnectionUri();
    process.env.AUTH_REQUIRED = env.AUTH_REQUIRED ?? "false";
    process.env.LOG_LEVEL = "silent";

    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    const app = moduleRef.createNestApplication<NestFastifyApplication>(new FastifyAdapter());
    await app.init();
    await app.getHttpAdapter().getInstance().ready(); // Fastify must be ready before requests
    return { app, container };
}
```

```ts
describe("task commands (I6–I10) + colon dispatch", () => {
    let app: TestApp;
    beforeAll(async () => { app = await createTestApp(); }, 120_000);
    afterAll(async () => { await app.app.close(); await app.container.stop(); });

    const server = () => app.app.getHttpServer();

    it("I7: :delegate without delegatedTo → 422 validation_failed", async () => {
        const id = await createTask(server());
        const res = await request(server()).post(`/tasks/${id}:delegate`).send({});
        expect(res.status).toBe(422);
        expect(res.body.error.code).toBe("validation_failed");
    });

    it.each(LIFECYCLE_COMMANDS)("I6: a completed task rejects :%s with 409", async (command, body) => {
        const id = await createTask(server());
        await request(server()).post(`/tasks/${id}:complete`).send({});
        const res = await request(server()).post(`/tasks/${id}:${command}`).send(body);
        expect(res.status).toBe(409);
        expect(res.body.error.code).toBe("invalid_state_transition");
    });
});
```

Assert **both** the status and `body.error.code` for every error path (422 / 404 / 409×both codes). Add an auth spec
that toggles `AUTH_REQUIRED=true` and checks 401 (no token) / 200 (valid token) / 200 on `/healthz` (see
`references/auth-oauth2.md`).

## Testing SSE

SSE is timing-sensitive: attach the subscriber, pause briefly so it's listening, then mutate. Read a **bounded** number
of frames so the test terminates, and parse frames out of the raw stream.

```ts
it("I20: live frame id == event id, with §8 names", async () => {
    const frames = readFrames(baseUrl, null, 2);     // resolves after 2 frames
    await sleep(500);                                // let the subscriber attach
    const id = (await request(server()).post("/tasks").send({ title: "x" })).body.task.id;
    await request(server()).post(`/tasks/${id}:complete`).send();

    const got = await frames;
    expect(got.map((f) => f.event)).toEqual(expect.arrayContaining(["task.created", "task.completed"]));
    for (const f of got) expect(f.id).toBeTruthy();
});

it("Last-Event-ID resumes strictly after the given id", async () => {
    const first = await readFrames(baseUrl, null, 2);
    const lastId = first.at(-1)?.id ?? null;
    const resumed = readFrames(baseUrl, lastId, 1);
    await sleep(500);
    await request(server()).patch(`/tasks/${taskId}`).send({ notes: "probe" });
    const got = await resumed;
    const seen = new Set(first.map((f) => f.id));
    for (const f of got) expect(seen.has(f.id)).toBe(false); // no replay of already-seen events
});
```

## Contract test

The emitted-≡-canonical test (deep-equal the served document against the parsed `openapi.yaml`) lives here; details and
the external Schemathesis fuzzer are in `references/openapi-contract.md`.

## What not to test, and how to keep it fast

- **Don't unit-test logging.** It's observability, not behavior; asserting log lines couples tests to wording.
- **Don't mock the database** in store/functional tests — a mock that returns canned rows can't violate a `UNIQUE`
  constraint, so it can't prove I18.
- **Don't re-test pure logic through HTTP.** If `decide` already proves I3 at the unit layer, the functional layer needs
  one happy-path and one error-path case, not the full matrix.
- **Share one container per spec file** (`beforeAll`), not per test, and reset state between tests by truncating or using
  fresh ids. Booting a fresh app per test is the usual reason a suite is slow.
- **TDD order:** write the failing test from the invariant → implement the smallest change → green → refactor. The
  domain layer should be entirely green before any controller exists.
