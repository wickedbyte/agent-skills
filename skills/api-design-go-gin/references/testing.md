# Testing: Unit & Functional

Two layers, fastest first: pure domain unit tests (no I/O) and in-process functional tests against a real Postgres. The
third layer — proving the running service matches its OpenAPI document — is in `openapi-contract.md`. Run everything with
`-race`.

## 1. Domain unit tests — table-driven, one block per rule

The pure core holds all the business rules, so it holds most of the tests. They need no Docker and run in milliseconds.
Use a **black-box** test package (`domain_test`) so you exercise only the exported surface, name each test after the
rule it covers, inject a fixed clock, and assert error _types_ with `errors.As`.

```go
package domain_test

var t0 = time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)

// A completed task cannot be completed again.
func TestCompleteIsTerminal(t *testing.T) {
    cases := []struct {
        name    string
        state   domain.Task
        wantErr bool
    }{
        {"actionable → complete ok", domain.Task{State: domain.StateActionable}, false},
        {"already completed → conflict", domain.Task{State: domain.StateCompleted}, true},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            _, err := domain.Decide(tc.state, domain.CompleteTask{}, t0)
            if tc.wantErr {
                var se *domain.StateTransitionError
                require.ErrorAs(t, err, &se)
                return
            }
            require.NoError(t, err)
        })
    }
}
```

Write the failing test from the spec rule first, then the code that satisfies it (TDD). Mark helpers with `t.Helper()`.
Do **not** unit-test logging.

## 2. Functional tests — httptest + a throwaway Postgres

Drive the real router in-process with `net/http/httptest` against a real Postgres started per test via
`testcontainers`. This exercises routing, binding, the store, transactions, and error mapping end-to-end — without a
running server or network.

```go
// testsupport: a disposable Postgres for integration tests (needs a Docker daemon).
func StartPostgres(ctx context.Context) (dsn string, terminate func(), err error) {
    ctr, err := postgres.Run(ctx, "postgres:17-alpine",
        postgres.WithDatabase("app"), postgres.WithUsername("app"), postgres.WithPassword("app"),
        postgres.BasicWaitStrategies(),
    )
    if err != nil {
        return "", nil, err
    }
    dsn, err = ctr.ConnectionString(ctx, "sslmode=disable")
    if err != nil {
        _ = ctr.Terminate(ctx)
        return "", nil, err
    }
    return dsn, func() { _ = ctr.Terminate(ctx) }, nil
}
```

```go
package httpapi_test

func newServer(t *testing.T) (http.Handler, *store.Store) {
    t.Helper()
    ctx := context.Background()
    dsn, terminate, err := testsupport.StartPostgres(ctx)
    require.NoError(t, err)
    t.Cleanup(terminate)
    require.NoError(t, store.Migrate(ctx, dsn))

    pool, err := pgxpool.New(ctx, dsn)
    require.NoError(t, err)
    t.Cleanup(pool.Close)

    app := &httpapi.App{Store: store.New(pool), Now: func() time.Time { return t0 }} // Auth nil → gate off
    return httpapi.NewRouter(app), store.New(pool)
}

func do(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
    t.Helper()
    var r *http.Request
    if body == "" {
        r = httptest.NewRequest(method, path, nil)
    } else {
        r = httptest.NewRequest(method, path, strings.NewReader(body))
        r.Header.Set("Content-Type", "application/json")
    }
    rec := httptest.NewRecorder()
    h.ServeHTTP(rec, r)
    return rec
}

func TestCreateTaskDefaults(t *testing.T) {
    h, _ := newServer(t)
    rec := do(t, h, http.MethodPost, "/tasks", `{"title":"Buy milk"}`)
    require.Equal(t, http.StatusCreated, rec.Code)

    var env struct{ Task map[string]any `json:"task"` }
    require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &env))
    assert.Equal(t, "actionable", env.Task["state"])
    assert.Equal(t, []any{}, env.Task["projectIds"], "must be [] not null")
}
```

Notes:

- Set `gin.SetMode(gin.TestMode)` in a `TestMain` to silence debug output.
- One fresh container per test is the simplest correctness story (full isolation). If suite time matters, share one
  container and isolate with a unique schema/database per test, or truncate between tests — but never share mutable rows
  across tests.
- Assert **status code and body shape**, including that required arrays serialize as `[]` and nullable fields appear as
  `null` — those are exactly what the schema fuzzer will also check.

## The gate

Run the full fmt/lint/vet/test gate after every change; the canonical command list lives in `toolchain.md`. A change is
done only when the whole gate is green **and**, for any endpoint change, the schema fuzzer passes against the running
service (see `openapi-contract.md`).
