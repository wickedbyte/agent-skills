# Domain Core: the Pure Decision Layer

The `domain` package is the pure core: plain types and decision functions that hold every business rule, importing only
the standard library. No `gin`, no `pgx`, no `context` plumbing for logic — the store maps domain types to and from
Postgres, and the HTTP layer maps them to and from the wire.

## Keep the domain pure

The flow for a command:

```
handler binds DTO → domain.Decide(state, cmd, now) → []Event (pure, no I/O)
        → store.Commit(...)  // append + project in one tx, NOTIFY, return new state
        → handler maps to JSON
```

- `domain` exposes pure functions — `Decide(state, cmd, now) ([]Event, error)` validates the guard and emits events;
  `Apply(state, event) State` folds. No `pgx`, no `context`, no clock-reading inside (the clock is a parameter). This is
  where all the real rules and all the unit tests live.

Injecting the clock as a parameter (rather than calling `time.Now()` inside the core) is what makes the decision logic
deterministic and testable; the HTTP layer reads `App.Now` at the boundary and passes the timestamp in.

This separation is what lets you unit-test every business rule with no database, and integration-test the thin store/HTTP
adapters against a real Postgres (see `testing.md`).
