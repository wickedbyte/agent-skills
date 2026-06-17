# Persistence: pgx + sqlc + goose

**Greenfield default.** If the project already has a datastore, use it and skip this — see *Adopt, Don't Impose* in SKILL.md.

The store is an adapter: it translates domain types to and from Postgres and never leaks `pgx` types or raw SQL errors
upward. Stack: `pgx/v5` for the driver and pool, `sqlc` to generate type-safe query code from SQL, `goose` for
versioned migrations.

## Why this stack

- **`pgx/v5`** speaks the native Postgres protocol (faster, typed errors, `LISTEN/NOTIFY`, `COPY`) — skip
  `database/sql` unless you need driver-agnosticism.
- **`sqlc`** generates Go from your SQL at build time: queries are checked against the schema, results are typed
  structs, and there's zero runtime reflection or ORM magic. You write SQL; you get functions.
- **`goose`** keeps migrations as ordered, reversible SQL files you can embed and run on boot.

## sqlc configuration

`sqlc.yaml` — read the schema **straight from the goose migrations** so generated types can never drift from the live
DDL:

```yaml
version: "2"
sql:
    - engine: postgresql
      schema: migrations # sqlc folds the Up side of each migration
      queries: internal/store/queries
      gen:
          go:
              package: db
              out: internal/store/db
              sql_package: pgx/v5
              emit_interface: true # generates a Querier interface — the seam for tests/tx
              emit_empty_slices: true # [] not nil for list results
              overrides:
                  - db_type: timestamptz
                    go_type: time.Time
                  - db_type: timestamptz
                    nullable: true
                    go_type: { type: time.Time, pointer: true }
```

Write queries as annotated SQL; `go tool sqlc generate` produces `internal/store/db`. Run `make sqlc-check` in CI
(regenerate, fail on diff) so the checked-in code always matches the SQL.

```sql
-- name: GetTask :one
SELECT * FROM tasks WHERE id = $1;

-- name: InsertEvent :exec
INSERT INTO events (id, stream_type, stream_id, version, type, data, occurred_at)
VALUES ($1, $2, $3, $4, $5, $6, $7);
```

## Migrations with goose, embedded and run on boot

```go
//go:embed migrations/*.sql
var migrationsFS embed.FS

func Migrate(ctx context.Context, databaseURL string) error {
    db, err := sql.Open("pgx/stdlib", databaseURL) // goose wants database/sql
    if err != nil {
        return fmt.Errorf("open for migrate: %w", err)
    }
    defer db.Close()
    goose.SetBaseFS(migrationsFS)
    if err := goose.SetDialect("postgres"); err != nil {
        return err
    }
    return goose.Up(db, "migrations")
}
```

## The store: pool in, typed methods out

```go
type Store struct {
    pool *pgxpool.Pool
    q    *db.Queries // sqlc-generated, bound to the pool
}

func New(pool *pgxpool.Pool) *Store {
    return &Store{pool: pool, q: db.New(pool)}
}

func (s *Store) Pool() *pgxpool.Pool { return s.pool } // for readiness Ping
```

Read methods translate `pgx.ErrNoRows` into a `(zero, false, nil)` "not found" triple — the HTTP layer maps `ok==false`
to `404`, and a real error to `500`:

```go
func (s *Store) GetTask(ctx context.Context, id string) (domain.Task, bool, error) {
    row, err := s.q.GetTask(ctx, id)
    if err != nil {
        if errors.Is(err, pgx.ErrNoRows) {
            return domain.Task{}, false, nil
        }
        return domain.Task{}, false, fmt.Errorf("get task %s: %w", id, err)
    }
    return toDomainTask(row), true, nil
}
```

## Transactions: the canonical pgx pattern

Wrap a transaction in a helper that takes a closure and a `*db.Queries` bound to the tx. The `defer Rollback` is a no-op
once `Commit` has run, so it's always safe:

```go
func (s *Store) inTx(ctx context.Context, fn func(*db.Queries) error) error {
    tx, err := s.pool.Begin(ctx)
    if err != nil {
        return fmt.Errorf("begin tx: %w", err)
    }
    defer func() { _ = tx.Rollback(ctx) }() // no-op after a successful Commit
    if err := fn(s.q.WithTx(tx)); err != nil {
        return err
    }
    if err := tx.Commit(ctx); err != nil {
        return fmt.Errorf("commit tx: %w", err)
    }
    return nil
}
```

`Queries.WithTx(tx)` returns a `*Queries` whose methods run inside the transaction — the same generated code runs in or
out of a tx, which is exactly what makes "do several writes atomically" trivial. Anything that must be consistent — a
write plus the read-back the response returns, an event append plus its projection update — goes in **one** `inTx`
closure. That gives you read-your-writes for free.

## Optimistic concurrency → 409

Guard concurrent updates with a `UNIQUE` constraint and let the database be the arbiter. For an append-only/event model:
`UNIQUE (stream_type, stream_id, version)`; for a row-versioned model: a `version` column you check in the `UPDATE …
WHERE id = $1 AND version = $2` and treat "0 rows affected" as a conflict. On the unique-violation path, translate the
Postgres error into a typed sentinel:

```go
var ErrVersionConflict = errors.New("version conflict")

func isUniqueViolation(err error) bool {
    var pgErr *pgconn.PgError
    return errors.As(err, &pgErr) && pgErr.Code == "23505" // unique_violation
}

// inside the append:
if err := q.InsertEvent(ctx, params); err != nil {
    if isUniqueViolation(err) {
        return ErrVersionConflict // handler maps to 409
    }
    return fmt.Errorf("insert event: %w", err)
}
```

You can also match a **specific** constraint (e.g. a slug uniqueness) by checking `pgErr.ConstraintName`, mapping
different constraints to different client errors. Always inspect via `errors.As(&pgErr)` — never substring-match the
message.

## The store maps domain types both ways

The pure `domain` core (see `domain-core.md`) emits events from a `Decide(state, cmd, now)` function; the store is what
persists them and reads them back, owning the translation in both directions:

- `store` owns the `convert.go`/`codec.go` mapping between domain types and the sqlc row/param structs, including
  small helpers for nullable columns (`*string ↔ pgtype.Text`) and for forcing `[]string{}` over `nil`.
- Centralize any narrowing conversion (e.g. `int → int32` for a Postgres `int4`) in one range-checked helper and
  suppress the `gosec` G115 warning there, once, with a comment — not scattered across call sites.

This separation is what lets you unit-test every business rule with no database, and integration-test the thin store/HTTP
adapters against a real Postgres (see `testing.md`).
