# Testing & OpenAPI Contract Conformance

Three layers, fastest first: pure domain unit tests (no I/O), in-process functional tests against a real Postgres, and
contract tests that prove the running service matches its OpenAPI document. Run everything with `-race`.

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

## 3. Contract conformance — serve, cover, fuzz

Two derived artifacts must agree with the OpenAPI document.

### Serve the canonical spec verbatim

Don't generate the spec from annotations (it drifts). Embed the canonical `openapi.yaml`, serve it as JSON at
`/openapi.json`, and keep the embedded copy in sync with a `make` target + CI check.

```go
//go:embed openapi.yaml
var specYAML []byte

func JSON() ([]byte, error) {
    var doc any
    if err := yaml.Unmarshal(specYAML, &doc); err != nil {
        return nil, fmt.Errorf("parse openapi: %w", err)
    }
    return json.Marshal(doc)
}
```

### Route-coverage test: router ≡ spec operations

Parse the spec's operations and assert the router's registered routes equal them — no missing operation, no extra route.
Custom-method operations (`/tasks/{id}:complete`) collapse onto their dispatcher route (`POST /tasks/:taskId`).

```go
func TestRouterCoversContract(t *testing.T) {
    ops, err := openapi.Operations() // [{Method, Path, OperationID}, …] from the spec
    require.NoError(t, err)

    expected := map[string]bool{}
    for _, op := range ops {
        expected[strings.ToUpper(op.Method)+" "+ginPath(op.Path)] = true
    }

    actual := map[string]bool{}
    for _, route := range httpapi.NewRouter(&httpapi.App{}).Routes() {
        actual[route.Method+" "+route.Path] = true
    }
    assert.Equal(t, expected, actual, "router routes must equal contract operations")
}

// ginPath: {param} → :param, and a trailing "{param}:command" → :param.
func ginPath(path string) string {
    segs := strings.Split(strings.Trim(path, "/"), "/")
    for i, s := range segs {
        if strings.HasPrefix(s, "{") {
            segs[i] = ":" + s[1:strings.Index(s, "}")]
        }
    }
    return "/" + strings.Join(segs, "/")
}
```

This single test catches a forgotten endpoint, a path typo, or a stray route the instant it diverges from the spec.

### Schema fuzzing against the live service

Property-based contract testing drives generated requests against the **running** service and checks every response
against the spec's declared schemas, status codes, and content types. [Schemathesis](https://schemathesis.readthedocs.io)
is the standard tool:

```bash
st run ./openapi.yaml --url http://localhost:8080
```

It finds: undocumented status codes, responses that violate the declared schema (missing required field, wrong type,
`null` where the schema forbids it), `additionalProperties` leaks, and malformed-input handling that doesn't match the
documented error responses. Run it in CI against the container started by `compose.yaml`.

## The gate (run on every change, in order)

```bash
gofumpt -l .          # empty = clean
golangci-lint run
go vet ./...
go test -race ./...   # unit + functional; success AND failure paths
make sqlc-check       # generated store matches the SQL (no drift)
go test ./internal/openapi/...   # route coverage vs the contract
```

A change is done only when the whole gate is green **and**, for any endpoint change, the schema fuzzer passes against
the running service. Anchor each test to the spec rule (or `operationId`) it verifies, and keep a checklist mapping
every documented behavior to a test name — that mapping is your evidence the contract is fully covered.
