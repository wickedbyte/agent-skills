# Persistence — Event Store, Projections, Migrations

**Greenfield default.** If the project already has a datastore, use it and skip this — see _Adopt, Don't Impose_ in SKILL.md.

The store is the only layer that knows SQL. It maps rows to domain types and back, appends events with optimistic
concurrency, updates read-model projections **in the same transaction**, and runs versioned migrations. The example is
event-sourced; a CRUD service keeps the same transactional-write and projection-as-read-model discipline without the
event log.

## `pg` + Kysely, with the date-parser gotcha

Kysely is a typed query builder over `pg` with no ORM identity map — ideal when you write every query deliberately. Two
setup details matter:

```ts
import { Kysely, PostgresDialect } from "kysely";
import { Pool, types } from "pg";

// GOTCHA: pg parses a DATE column (OID 1082) into a JS Date at local midnight,
// which shifts "YYYY-MM-DD" across time zones. Override it to return the raw text.
types.setTypeParser(1082, (value: string) => value);

export function createPool(connectionString: string): Pool {
    return new Pool({ connectionString });
}

export function createDb(pool: Pool): Kysely<Database> {
    return new Kysely<Database>({ dialect: new PostgresDialect({ pool }) });
}
```

The date-type-parser override is not optional. Without it, a task with `dueDate = "2026-01-01"` read back in a `UTC+N`
process can become `"2025-12-31"`. Date-only fields are strings end to end (DB → domain → wire); only RFC3339
timestamps are time-zone-aware.

## The schema type, kept in lockstep with migrations

Kysely needs a `Database` interface describing every table. Hand-write it next to the migrations and keep the two in
agreement (or generate it with `kysely-codegen` against the migrated DB):

```ts
export interface Database {
    events: EventsTable;
    task_projection: TaskProjectionTable;
    project_projection: ProjectProjectionTable;
    task_project_projection: TaskProjectProjectionTable; // (task_id, project_id, position)
}

export interface EventsTable {
    id: string;
    stream_type: "Task" | "Project";
    stream_id: string;
    version: number;
    type: string;
    data: JSONColumnType<Record<string, unknown>>;
    occurred_at: ColumnType<string, string, string>; // timestamptz as ISO string
}
```

## Migrations — versioned, run on boot

Use Kysely's migrator with a static provider so migrations ship in the bundle (no filesystem globbing in a slim
container). Run them from the DB module's lifecycle hook so a fresh container is immediately ready.

```ts
class StaticMigrationProvider implements MigrationProvider {
    getMigrations(): Promise<Record<string, Migration>> {
        return Promise.resolve({ "0001_init": init0001 });
    }
}

export async function migrateToLatest(db: Kysely<Database>): Promise<void> {
    const { error, results } = await db /* via Migrator */
        .migrateToLatest();
    for (const r of results ?? []) {
        if (r.status === "Error")
            throw new Error(`migration ${r.migrationName} failed`);
    }
    if (error)
        throw error instanceof Error
            ? error
            : new Error("migration failed", { cause: error });
}
```

The init migration encodes the invariants in the schema itself — they are a second line of defense behind `decide`:

```ts
await sql`
    CREATE TABLE events (
        id          text        PRIMARY KEY,
        stream_type text        NOT NULL CHECK (stream_type IN ('Task','Project')),
        stream_id   text        NOT NULL,
        version     integer     NOT NULL CHECK (version >= 1),
        type        text        NOT NULL,
        data        jsonb       NOT NULL,
        occurred_at timestamptz NOT NULL,
        CONSTRAINT events_stream_version_unique UNIQUE (stream_type, stream_id, version)
    )`.execute(db);

await sql`CREATE INDEX events_stream_idx ON events (stream_id, version)`.execute(
    db,
);

await sql`
    CREATE TABLE task_projection (
        id text PRIMARY KEY,
        /* …columns… */
        start_date date,
        due_date   date,
        version integer NOT NULL,
        CONSTRAINT task_date_range_check CHECK (due_date IS NULL OR start_date <= due_date)
    )`.execute(db);
```

The `UNIQUE (stream_type, stream_id, version)` constraint is what makes optimistic concurrency real (below); the
`CHECK` constraints make a projection that violates an invariant un-writable even if a bug in `decide` let it through.

## The command path — one transaction, read-your-writes

Every command runs the same six steps. The service orchestrates them; the store owns the transactional tail:

```
load stream → fold to current state → decide(state, command, now)
  → append event(s) with the expected version
  → update projection(s)  ── same transaction ──
  → NOTIFY for SSE        ──
  → return the new projection
```

```ts
async commitTask(
    streamId: string,
    base: TaskAggregate,                 // the folded state we decided against
    payloads: readonly TaskEventData[],  // what decide() returned
    now: Date,
): Promise<TaskAggregate> {
    // stamp each payload with id, version = base.version + n, occurredAt
    const committed = this.stamp(streamId, "Task", base.version, payloads, isoNow(now));
    const state = committed.reduce(applyTask, base); // fold forward in memory

    await this.db.transaction().execute(async (trx) => {
        await this.appendEvents(trx, committed);     // INSERT … (UNIQUE catches stale version)
        await writeTaskProjection(trx, state);       // UPSERT the read model
        await this.notifyAll(trx, committed);        // NOTIFY taskflow_events, '<event_id>'
    });
    return state;
}
```

Why one transaction:

- **Read-your-writes.** The projection is updated before the HTTP response returns, so a `GET` immediately after a
  command sees the new state. No eventual-consistency window in v1.
- **Atomic notify.** The `NOTIFY` rides the same transaction as the append, so a subscriber can never be told about an
  event that later rolls back. (Postgres delivers `NOTIFY` payloads at commit.)
- **No torn writes.** Either the event, the projection, and the notify all land, or none do.

The service wraps load + decide + commit, mapping the optimistic-concurrency failure:

```ts
private async execute(taskId: string, toCommand: (s: TaskAggregate) => TaskCommand): Promise<TaskAggregate> {
    const events = await this.store.loadStream(taskId);
    if (events.length === 0) throw new NotFoundError(`task ${taskId} not found`);
    const state = events.reduce(applyTask, emptyTask());
    const command = toCommand(state);
    const payloads = decideTask(state, command, this.clock.now());
    return this.store.commitTask(taskId, state, payloads, this.clock.now());
}
```

## Optimistic concurrency (lost-update protection)

The expected version is `base.version`; the appended events get `base.version + 1 …`. If a concurrent writer already
advanced the stream, the `UNIQUE (stream_id, version)` insert fails. Translate that specific failure into a typed
error, which the filter renders as `409 conflict`:

```ts
export class VersionConflictError extends Error {}

function isUniqueViolation(err: unknown): boolean {
    return (
        typeof err === "object" &&
        err !== null &&
        (err as { code?: string }).code === "23505"
    );
}

// in appendEvents:
try {
    await trx.insertInto("events").values(rows).execute();
} catch (err) {
    if (isUniqueViolation(err))
        throw new VersionConflictError("stream advanced concurrently");
    throw err;
}
```

A unique violation on a **slug** (`23505` on the projects slug index) maps instead to a `SlugConflictError` → also 409
but with `details.field = "slug"`; distinguish by constraint name.

## Projections and rebuild

Projections are caches. `writeTaskProjection(trx, state)` is an upsert keyed by id; the project-membership edges
(`task_project_projection`) are rewritten wholesale when `TaskProjectsAssigned` lands (delete-then-insert with
`position`), matching the replace-not-merge rule. Because `foldTask` reproduces an aggregate from its stream, you can
truncate every projection and rebuild from `events` — keep a `rebuild()` for tests and recovery:

```ts
async rebuild(): Promise<void> {
    await this.db.transaction().execute(async (trx) => {
        await trx.deleteFrom("task_projection").execute();
        // replay all Task streams in (stream_id, version) order, fold, upsert
    });
}
```

A test that mutates, truncates, rebuilds, and asserts the projection is byte-identical proves the projection is a pure
function of the log.

## Reads and the saved views

The read layer (`task-reads.ts`) queries projections directly — no event replay on the read path. Each saved view is a
`WHERE` clause that must agree with its `domain/views.ts` predicate. Keep them adjacent so a change to one forces a
change to the other, and test the SQL view against the pure predicate over a fixture spanning all states.

```ts
// GET /views/overdue — must match isOverdue()
db.selectFrom("task_projection")
    .selectAll()
    .where("state", "in", ["actionable", "delegated"])
    .where("due_date", "<", today)
    .where("completed_at", "is", null)
    .where("cancelled_at", "is", null);
```

## Valkey / Redis — optional, not for the write path

The contract scaffolds a Valkey service but the v1 write path doesn't need it: Postgres' `UNIQUE` constraint already
gives correct optimistic concurrency without a distributed lock. Reach for Valkey only for genuinely cross-process
concerns — a rate limiter, a cache of expensive reads, or a serialization lock if you later move projections to async
workers. Don't add it to the critical path "for safety"; it would be a second source of truth.
