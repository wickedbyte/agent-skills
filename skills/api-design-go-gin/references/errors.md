# The Error Envelope & Status-Code Mapping

The HTTP layer turns every domain/store error into one consistent JSON envelope. No business logic here — map, don't
decide. (For binding and validating the request into a typed command, see `validation.md`.)

## The single error envelope

One response shape for every error, defined once:

```go
type errorEnvelope struct {
    Error errorBody `json:"error"`
}
type errorBody struct {
    Code    string         `json:"code"`
    Message string         `json:"message"`
    Details map[string]any `json:"details,omitempty"`
}

func respondError(c *gin.Context, status int, code, message string, details map[string]any) {
    c.JSON(status, errorEnvelope{Error: errorBody{Code: code, Message: message, Details: details}})
}
```

## Map domain/store errors → status codes

`handleError` is the only place that knows the error→status mapping. Drive it with `errors.As`/`errors.Is` (the
`errorlint` linter enforces this over string matching), and never leak a raw error to the client:

```go
func handleError(c *gin.Context, err error) {
    var verr *domain.ValidationError
    if errors.As(err, &verr) {
        respondError(c, http.StatusUnprocessableEntity, "validation_failed", verr.Reason,
            map[string]any{"field": verr.Field})
        return
    }
    var serr *domain.StateTransitionError
    if errors.As(err, &serr) {
        respondError(c, http.StatusConflict, "invalid_state_transition", serr.Error(), nil)
        return
    }
    if errors.Is(err, store.ErrVersionConflict) {
        respondError(c, http.StatusConflict, "conflict", "modified concurrently; retry", nil)
        return
    }
    // Unknown: log the real error, return a safe generic one.
    slog.Error("unhandled request error", "error", err.Error(), "path", c.FullPath())
    respondError(c, http.StatusInternalServerError, "internal_error", "internal error", nil)
}
```

### Status-code conventions

| Status | Code (`code`)                           | When                                                       |
| ------ | --------------------------------------- | ---------------------------------------------------------- |
| 200    | —                                       | Successful GET / command returning state                   |
| 201    | —                                       | Resource created (return the full representation)          |
| 400    | `bad_request`                           | Malformed request line/params the schema rejects           |
| 401    | `unauthorized`                          | Missing/invalid bearer token (+ `WWW-Authenticate` header) |
| 403    | `forbidden`                             | Authenticated but lacking the required scope/permission    |
| 404    | `not_found`                             | Resource (or command resource) does not exist              |
| 405    | —                                       | Known path, undocumented method (`HandleMethodNotAllowed`) |
| 409    | `conflict` / `invalid_state_transition` | Optimistic-concurrency clash; illegal state change         |
| 422    | `validation_failed`                     | Well-formed JSON that violates a field/shape rule          |
| 500    | `internal_error`                        | Unexpected; logged server-side, generic message out        |

Match the **exact** codes and messages your OpenAPI documents — the schema fuzzer will check response shapes against the
spec's declared responses.
