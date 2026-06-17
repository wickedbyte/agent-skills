# Persistence with `sqlx`

**Greenfield default.** If the project already has a datastore, use it and skip this — see *Adopt, Don't Impose*
in SKILL.md.

`sqlx` gives async, compile-time-checked SQL without an ORM: you write SQL, and the `query!`/`query_as!` macros
verify it against a real database schema at build time. This catches column/type drift the moment it happens —
the single highest-value safety net for an agentic backend build.

## Pool & migrations

```rust
// src/db.rs
use sqlx::PgPool;
use sqlx::migrate::{MigrateError, Migrator};
use sqlx::postgres::PgPoolOptions;

/// Migrations embedded at compile time from ./migrations, so they travel in the
/// binary and run identically locally, in CI, and in the container.
pub static MIGRATOR: Migrator = sqlx::migrate!("./migrations");

pub async fn connect(database_url: &str) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new().max_connections(10).connect(database_url).await
}

/// Idempotent: applied migrations are tracked in _sqlx_migrations and skipped.
pub async fn run_migrations(pool: &PgPool) -> Result<(), MigrateError> {
    MIGRATOR.run(pool).await
}
```

Migrations are timestamped/sequential `.sql` files in `migrations/` (`0001_init.up.sql`, …). Generate them with
`sqlx migrate add <name>`; run with the embedded `MIGRATOR` at boot (above) or `sqlx migrate run` in CI.

## Compile-time-checked queries + the offline cache

`sqlx::query!` and `query_as!` connect to a database **at compile time** (via `DATABASE_URL`) to verify the SQL and
infer result types. For CI and Docker builds that have no live DB, commit the **offline cache**:

```bash
# Generate/refresh .sqlx metadata against a live dev DB:
cargo sqlx prepare -- --all-targets    # writes .sqlx/ — COMMIT this directory
# In CI / Docker, build offline so no DB is needed:
SQLX_OFFLINE=true cargo build --release
# Gate that the cache is fresh & complete (run it in the check gate):
cargo sqlx prepare --check -- --all-targets
```

`--all-targets` includes queries in tests, because `clippy --all-targets` and `cargo test` compile them offline too.
A stale `.sqlx` is a build break — treat `sqlx prepare --check` as part of the gate (`toolchain.md`).

```rust
// A checked insert: `query!` validates columns/types against the schema.
sqlx::query!(
    r#"INSERT INTO events (id, stream_type, stream_id, version, type, data, occurred_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7)"#,
    id, stream_type, stream_id, version, event_type, data, occurred_at,
)
.execute(conn)
.await?;
```

```rust
// `query_as!` maps rows into a struct; the `"col!"` cast asserts non-null where
// the inferred nullability is too loose (e.g. aggregates / COALESCE results).
struct ProjectRow { id: String, name: String, slug: String, version: i32 }

let rows = sqlx::query_as!(
    ProjectRow,
    r#"SELECT id, name, slug, version FROM project_projection WHERE NOT archived ORDER BY created_at, id"#,
)
.fetch_all(&self.pool)
.await?;
```

## The store: load → fold → commit

Wrap the pool in a cheap-to-clone `Store` and expose intention-revealing methods. Reads fold an event stream (or
select a projection row); writes append and project **in one transaction**.

```rust
#[derive(Clone)]
pub struct Store { pool: PgPool }   // PgPool is Arc inside → clone is cheap

impl Store {
    pub fn new(pool: PgPool) -> Self { Self { pool } }
    pub fn pool(&self) -> &PgPool { &self.pool }   // for readiness checks / listeners
}
```

### Transactional write — append + project (+ notify) atomically

The command path must make all of its writes land together, so a reader never sees events without the matching
projection (read-your-writes). Begin one transaction, do every write on it, commit at the end:

```rust
pub async fn commit_task(
    &self, stream_id: &TaskId, base: Option<Task>, events: Vec<TaskEvent>, now: DateTime<Utc>,
) -> Result<Task, StoreError> {
    // Stamp version/occurred_at and fold to the new state (pure).
    let base_version = base.as_ref().map_or(0, |t| t.version);
    let mut state = base;
    let mut stamped = Vec::with_capacity(events.len());
    for (offset, data) in events.into_iter().enumerate() {
        let version = base_version + 1 + i32::try_from(offset).unwrap_or(i32::MAX);
        let record = DomainEvent::new(stream_id.as_str(), version, now, data);
        state = Some(apply(state, &record));
        stamped.push((EventId::generate(), record));
    }
    let new_state = match state {
        Some(s) if stamped.is_empty() => return Ok(s),  // no-op (e.g. empty PATCH)
        Some(s) => s,
        None => unreachable!("capture yields ≥1 event; commands fold an existing base"),
    };

    let mut tx = self.pool.begin().await?;
    for (id, record) in &stamped {
        let (event_type, data) = codec::encode_task(&record.data)?;
        event_store::insert_event(&mut tx, id.as_str(), "Task", stream_id.as_str(),
                                  record.version, event_type, &data, record.occurred_at).await?;
    }
    projections::write_task_projection(&mut tx, &new_state).await?;
    for (id, _) in &stamped {
        event_store::notify_event(&mut tx, id.as_str()).await?;  // NOTIFY inside the tx
    }
    tx.commit().await?;
    Ok(new_state)
}
```

Pass `&mut *tx` (or `&mut tx` where the signature wants `&mut PgConnection`) into each helper so they all execute on
the same transaction. A `tx` dropped without `commit` rolls back — so any early `?` return aborts the whole write.

For a plain **CRUD** service the shape is identical, just simpler: validate in the service layer, then `INSERT`/
`UPDATE`/`DELETE` (multiple statements in one `begin()…commit()` when they must be atomic).

## Optimistic concurrency from a unique constraint

Don't `SELECT … FOR UPDATE` then write. Make concurrent conflicts impossible with a unique key — for event sourcing,
`UNIQUE (stream_type, stream_id, version)`; for CRUD, a `version` column checked in the `UPDATE`'s `WHERE`. A losing
writer hits a unique violation; classify it and surface a typed conflict the edge maps to 409:

```rust
match result {
    Ok(_) => Ok(()),
    Err(e) if is_unique_violation(&e) => Err(StoreError::VersionConflict),  // → 409
    Err(e) => Err(e.into()),
}

pub(super) fn is_unique_violation(err: &sqlx::Error) -> bool {
    err.as_database_error().is_some_and(sqlx::error::DatabaseError::is_unique_violation)
}
pub(super) fn is_constraint_violation(err: &sqlx::Error, constraint: &str) -> bool {
    err.as_database_error().and_then(sqlx::error::DatabaseError::constraint) == Some(constraint)
}
```

`is_constraint_violation` lets you distinguish, e.g., a slug-uniqueness violation from a version conflict by the
constraint name, and map each to its own typed error.

## Reads: projections / read models

List, detail, and "view" endpoints read a denormalized projection table (or a SQL view) with a single `query_as!` —
no event replay on the read path. Centralize the shared `SELECT` so a new column is added in one place:

```rust
// I14 — "today": actionable tasks due on/before today.
pub async fn view_today(&self, today: NaiveDate) -> Result<Vec<Task>, StoreError> {
    let rows = sqlx::query_as!(
        TaskRow,
        r#"SELECT id, title, state, start_date, due_date, version
           FROM task_projection
           WHERE state = 'actionable' AND (start_date IS NULL OR start_date <= $1::date)
           ORDER BY due_date NULLS LAST, created_at, id"#,
        today,
    )
    .fetch_all(&self.pool)
    .await?;
    Ok(rows.into_iter().map(Task::from).collect())
}
```

Bind filters as nullable params so one query serves "filtered" and "unfiltered" (`($1::text IS NULL OR state = $1)`),
and aggregate child collections in-query (`array_agg(...)` with a `COALESCE` to an empty array) to avoid N+1s.

If projections are derivable purely from the log (event sourcing), keep a `rebuild()` that truncates and replays —
it's both a recovery tool and a property-test oracle (replay must reproduce the same projection; see `testing.md`).
