# Request Parsing, Validation & the Error Envelope

The HTTP layer's job is to turn an untrusted request into a typed domain command (or reject it), and to turn every
domain/store error into one consistent JSON envelope. No business logic here — bind, validate shape, convert, delegate,
map.

## Decode with unknown-field rejection

OpenAPI schemas with `additionalProperties: false` require rejecting unknown keys. Gin's `ShouldBindJSON` uses
`encoding/json`, which **silently ignores** unknown fields — so it does **not** enforce that constraint. Decode
explicitly with `DisallowUnknownFields`:

```go
// bindJSON decodes a required body, rejecting unknown fields and trailing data,
// and writes a 422 on any failure. Returns false when it has already responded.
func bindJSON(c *gin.Context, dst any) bool {
    body, ok := readBody(c)
    if !ok {
        return false
    }
    return decodeBody(c, body, dst)
}

func decodeBody(c *gin.Context, body []byte, dst any) bool {
    dec := json.NewDecoder(bytes.NewReader(body))
    dec.DisallowUnknownFields()
    if err := dec.Decode(dst); err != nil {
        respondError(c, http.StatusUnprocessableEntity, "validation_failed",
            "invalid request body: "+err.Error(), nil)
        return false
    }
    if dec.More() { // reject trailing garbage after the JSON value
        respondError(c, http.StatusUnprocessableEntity, "validation_failed",
            "unexpected trailing data", nil)
        return false
    }
    return true
}
```

Read the body once up front so you can also reject inputs the database can't store (Postgres `text`/`jsonb` cannot hold
a NUL byte) as a clean `422` rather than a surprise `500` on insert:

```go
func readBody(c *gin.Context) ([]byte, bool) {
    if c.Request.Body == nil {
        return nil, true
    }
    body, err := io.ReadAll(c.Request.Body)
    if err != nil {
        respondError(c, http.StatusUnprocessableEntity, "validation_failed", "could not read body", nil)
        return nil, false
    }
    if bytes.IndexByte(body, 0) >= 0 {
        respondError(c, http.StatusUnprocessableEntity, "validation_failed", "body must not contain NUL", nil)
        return nil, false
    }
    return body, true
}
```

For endpoints whose body is optional, add `bindOptionalJSON`: an empty body leaves `dst` at its zero value and succeeds.

## When to use validator tags vs. manual checks

`validator/v10` (the validator Gin's binding uses) is great for **single-field** rules via struct tags:

```go
type createTaskRequest struct {
    Title      string   `json:"title" binding:"required,max=200"`
    ProjectIDs []string `json:"projectIds" binding:"dive,required"`
}
```

Use it for `required`, length/range, enum membership (`oneof=`), and format checks. But reach for explicit code when:

- The rule is **cross-field** or **stateful** (e.g. "dueDate must be ≥ startDate", "can't complete a cancelled task") —
  that belongs in the **domain** layer's decision function, returning a typed `ValidationError` or
  `StateTransitionError`, not in a tag.
- You need **unknown-field rejection** or **tri-state** semantics — tags can't express those; use the manual decoder.

Keep field-shape validation at the edge; keep meaning/transition validation in `domain`. The handler is the wiring
between them.

## Tri-state optional fields (PATCH semantics)

A `*string` can represent "value" and "null" but not "absent". For `PATCH` (and `null`-clears-the-field semantics) you
need three states: **absent** (leave unchanged), **explicit null** (clear), **value** (set). Model it with a small type
and a custom unmarshaler:

```go
// optionalString distinguishes an absent field (Set == false) from an explicit
// null (Set == true, Value == nil) from a value (Set == true, Value != nil).
type optionalString struct {
    Set   bool
    Value *string
}

func (o *optionalString) UnmarshalJSON(b []byte) error {
    o.Set = true // UnmarshalJSON is only called when the key is present
    if string(b) == "null" {
        o.Value = nil
        return nil
    }
    return json.Unmarshal(b, &o.Value)
}
```

A `PATCH` DTO then enforces `minProperties: 1` by checking that at least one field was set:

```go
type patchTaskRequest struct {
    Title *string        `json:"title"`
    Notes optionalString `json:"notes"`
}
// in the handler:
if req.Title == nil && !req.Notes.Set {
    respondValidation(c, "", "patch must set at least one of title, notes")
    return
}
```

Mirror the same tri-state in the domain command type (`domain.OptionalString{Set bool; Value *string}`) so the wire
distinction survives all the way to the decision logic.

## Convert wire → domain in the DTO, not the handler

Give each request DTO a `toCommand()` that parses strings into typed domain values and returns a `ValidationError` on
bad input. The handler stays linear:

```go
func (r createTaskRequest) toCommand() (domain.CaptureTask, error) {
    cmd := domain.CaptureTask{Title: r.Title, ProjectIDs: nonNilStrings(r.ProjectIDs)}
    var err error
    if cmd.StartDate, err = parseDatePtr("startDate", r.StartDate); err != nil {
        return cmd, err
    }
    if cmd.DueDate, err = parseDatePtr("dueDate", r.DueDate); err != nil {
        return cmd, err
    }
    return cmd, nil
}

func parseDatePtr(field string, s *string) (*domain.Date, error) {
    if s == nil {
        return nil, nil
    }
    d, err := domain.ParseDate(*s) // strict YYYY-MM-DD, round-trip checked
    if err != nil {
        return nil, &domain.ValidationError{Field: field, Reason: field + " must be YYYY-MM-DD"}
    }
    return &d, nil
}
```

Two boundary rules worth enforcing:

- **Force empty slices, not nil**, on output so JSON emits `[]` not `null` where the schema says an array is required:
  `func nonNilStrings(s []string) []string { if s == nil { return []string{} }; return s }`.
- **Date-only vs timestamp**: model `YYYY-MM-DD` fields as a dedicated `Date` type (not `time.Time`) so the compiler
  keeps them distinct from RFC3339 lifecycle timestamps; format timestamps as RFC3339 UTC at the edge.

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

| Status | Code (`code`)             | When                                                             |
| ------ | ------------------------- | --------------------------------------------------------------- |
| 200    | —                         | Successful GET / command returning state                        |
| 201    | —                         | Resource created (return the full representation)               |
| 400    | `bad_request`             | Malformed request line/params the schema rejects                |
| 401    | `unauthorized`            | Missing/invalid bearer token (+ `WWW-Authenticate` header)      |
| 403    | `forbidden`               | Authenticated but lacking the required scope/permission         |
| 404    | `not_found`               | Resource (or command resource) does not exist                   |
| 405    | —                         | Known path, undocumented method (`HandleMethodNotAllowed`)      |
| 409    | `conflict` / `invalid_state_transition` | Optimistic-concurrency clash; illegal state change |
| 422    | `validation_failed`       | Well-formed JSON that violates a field/shape rule               |
| 500    | `internal_error`          | Unexpected; logged server-side, generic message out             |

Match the **exact** codes and messages your OpenAPI documents — the schema fuzzer will check response shapes against the
spec's declared responses.
