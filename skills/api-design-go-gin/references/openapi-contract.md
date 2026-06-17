# OpenAPI Contract Conformance

Two derived artifacts must agree with the OpenAPI document: the served spec and the router's routes. A schema fuzzer
then drives the running service against the spec. (For the unit and functional test layers, see `testing.md`.)

## Serve the canonical spec verbatim

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

## Route-coverage test: router ≡ spec operations

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

The same assertion, viewed from the routing side: prove the router's registered routes equal the OpenAPI operations — no
missing operation, no extra route. Custom-method operations collapse onto their dispatcher route.

```go
router := httpapi.NewRouter(&httpapi.App{})
actual := map[string]bool{}
for _, route := range router.Routes() {
    actual[route.Method+" "+route.Path] = true
}
// expected built from openapi.Operations(), converting {param} → :param and
// the trailing "{param}:command" → :param (the dispatcher route).
assert.Equal(t, expected, actual)
```

This catches a forgotten route or a typo'd path the moment it diverges from the contract.

## Schema fuzzing against the live service

Property-based contract testing drives generated requests against the **running** service and checks every response
against the spec's declared schemas, status codes, and content types. [Schemathesis](https://schemathesis.readthedocs.io)
is the standard tool:

```bash
st run ./openapi.yaml --url http://localhost:8080
```

It finds: undocumented status codes, responses that violate the declared schema (missing required field, wrong type,
`null` where the schema forbids it), `additionalProperties` leaks, and malformed-input handling that doesn't match the
documented error responses. Run it in CI against the container started by `compose.yaml`.
