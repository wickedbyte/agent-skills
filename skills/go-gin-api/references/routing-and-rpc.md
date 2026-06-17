# Routing: REST + RPC Custom Methods

Gin's router is httprouter-derived: fast, radix-tree, one handler per (method, path). Build the engine explicitly,
group by auth boundary, and handle the resource-action RPC convention with a colon dispatcher.

## Build the engine explicitly

Never use `gin.Default()` in production — it bundles a logger and recovery you should choose yourself. Start from
`gin.New()`:

```go
func NewRouter(app *App) *gin.Engine {
    r := gin.New()
    r.Use(gin.Recovery())          // turn panics into 500s; add your own logging middleware
    r.HandleMethodNotAllowed = true // known path + undocumented method → 405, not 404

    // Meta endpoints — always open (no auth gate).
    r.GET("/healthz", healthz)
    r.GET("/readyz", app.readyz)
    r.GET("/openapi.json", app.openapiDoc)

    // Everything else behind the optional auth gate.
    api := r.Group("/")
    if app.Auth != nil {
        api.Use(app.Auth)
    }

    // REST resources.
    api.POST("/tasks", app.createTask)
    api.GET("/tasks", app.listTasks)
    api.GET("/tasks/:taskId", app.getTask)
    api.PATCH("/tasks/:taskId", app.patchTask)

    // RPC custom methods share the collection's POST/:id route (see below).
    api.POST("/tasks/:taskId", app.dispatchTaskCommand)

    // Sub-resources / views.
    api.GET("/views/today", app.viewToday)

    return r
}
```

**Middleware order matters:** recovery and request-logging first (so they wrap everything), then auth, then route-group
or per-route middleware. Register the always-open meta routes *outside* the authed group.

### Organize routes by resource

For larger APIs, give each resource its own file with a `register(api *gin.RouterGroup, app *App)` function and call
them from `NewRouter`. Keeps `NewRouter` a readable table of contents and the handlers near their routes.

## RPC custom methods: `POST /resource/{id}:action`

The contract uses **resource-action custom methods** (Google AIP-136 style): a literal colon separates the resource id
from the action — `POST /tasks/{taskId}:complete`, `POST /tasks/{taskId}:assignProjects`. This keeps non-CRUD
operations RESTful-adjacent without inventing verbs in the path hierarchy.

### Why a dispatcher, not one route per action

Gin's `:param` wildcard matches a path segment but **stops at `/`** — and the literal `:` is an ordinary character
inside a segment. So a single registered route `POST /tasks/:taskId` matches `POST /tasks/01J…:complete`, and
`c.Param("taskId")` returns the **whole** segment `"01J…:complete"`, colon and all. You cannot register
`/tasks/:taskId:complete` as a distinct route — httprouter rejects a wildcard sharing a segment with literal text.

The clean solution: register **one** `POST /tasks/:taskId` and split off the action in the handler.

```go
// splitCommand splits "{id}:{command}" on the LAST colon. ok is false when there
// is no colon or either side is empty (i.e. it is not a command invocation).
func splitCommand(raw string) (id, command string, ok bool) {
    i := strings.LastIndex(raw, ":")
    if i < 0 {
        return "", "", false
    }
    id, command = raw[:i], raw[i+1:]
    if id == "" || command == "" {
        return "", "", false
    }
    return id, command, true
}
```

Split on the **last** colon so an id that itself contains a colon (e.g. a URN-like id) still parses — the action is
always the final `:segment`. Unit-test this helper directly, including ids with no colon and ids containing colons.

### The dispatcher

```go
func (a *App) dispatchTaskCommand(c *gin.Context) {
    id, command, ok := splitCommand(c.Param("taskId"))
    if !ok {
        // POST /tasks/{id} with no command is not a defined operation.
        respondNotFound(c, "task command")
        return
    }
    switch command {
    case "complete":
        a.completeTask(c, id)
    case "cancel":
        a.cancelTask(c, id)
    case "assignProjects":
        a.assignProjects(c, id)
    default:
        respondNotFound(c, "task command")
    }
}
```

Each `case` binds its own request DTO, calls the domain core, and maps the result — see
`parsing-and-validation.md`. A typical command handler:

```go
func (a *App) completeTask(c *gin.Context, id string) {
    var req completeTaskRequest
    if !bindOptionalJSON(c, &req) { // some commands take an optional body
        return
    }
    a.execCommand(c, id, domain.CompleteTask{CompletedAt: parseTimeLenient(req.CompletedAt)})
}
```

### Reject the wrong method on a command path

A plain resource id never contains a colon (the OpenAPI `taskId` pattern is `^[^:]+$`). So a `GET`/`PATCH` on
`/tasks/{id}:complete` is a wrong-method hit on a command resource — only `POST` is valid there. Catch it in the
`GET`/`PATCH` handlers and return `405`:

```go
func rejectCommandPath(c *gin.Context, id string) bool {
    if strings.Contains(id, ":") {
        c.AbortWithStatus(http.StatusMethodNotAllowed)
        return true
    }
    return false
}

func (a *App) getTask(c *gin.Context) {
    if rejectCommandPath(c, c.Param("taskId")) {
        return
    }
    // … normal GET …
}
```

## Path and query parameters

- **Path params:** `c.Param("taskId")`. Validate/normalize before use.
- **Query params:** prefer `c.GetQuery("state")` (returns `value, ok`) over `c.Query` so you can distinguish "absent"
  from "empty". Parse leniently for filter endpoints that document only a `200`:

```go
func parseListFilter(c *gin.Context) store.ListFilter {
    f := store.ListFilter{}
    if s, ok := c.GetQuery("state"); ok && s != "" {
        f.State = &s
    }
    f.IncludeCompleted = parseBoolQuery(c, "includeCompleted")
    return f
}

func parseBoolQuery(c *gin.Context, name string) bool {
    if s, ok := c.GetQuery(name); ok {
        if v, err := strconv.ParseBool(s); err == nil {
            return v
        }
    }
    return false // unparseable filter → ignored, since list documents only 200
}
```

Whether a malformed filter is a `422` or silently ignored is a **contract decision**: if the operation documents a
`422`, validate and reject; if it documents only `200`, drop the bad filter (an unknown enum value just matches no rows).
Read the spec; don't guess.

## The routing contract test

Prove the router's registered routes equal the OpenAPI operations — no missing operation, no extra route. Custom-method
operations collapse onto their dispatcher route. (Full code in `testing-and-contract.md`.)

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
