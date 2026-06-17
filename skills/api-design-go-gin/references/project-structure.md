# Project Structure, Tooling & Server Lifecycle

How to lay out the module, pull dependencies, configure the lint/format gate, build a minimal container image, load
configuration, and wire + gracefully shut down the server.

## Module layout

Use `internal/` so nothing leaks as a public API of the module, one package per concern, and `cmd/<binary>` for
entrypoints:

```
yourapi/
  go.mod  go.sum
  Makefile  Dockerfile  compose.yaml
  .golangci.yml  sqlc.yaml
  migrations/                  # goose SQL (embedded via //go:embed)
  cmd/
    server/main.go             # the only place that wires concrete dependencies
    seed/main.go               # optional one-shot jobs
  internal/
    config/config.go           # env → typed Config
    domain/                    # pure core (decide/apply + types); imports only stdlib
    store/                     # pgx adapter
      db/                      # sqlc-generated — DO NOT EDIT
      queries/*.sql
    httpapi/                   # Gin layer
    auth/auth.go               # OAuth2 resource-server middleware
    openapi/                   # embed + serve the canonical spec
    testsupport/               # shared test helpers (testcontainers, etc.)
```

**Dependency direction is inward and acyclic:** `cmd → httpapi → store → domain`; `auth` and `openapi` are leaves.
`domain` never imports `gin`, `pgx`, or `store`. If you find yourself importing `gin` into `domain`, the logic is in the
wrong layer.

## Initialize the module and pull current deps

```bash
go mod init github.com/you/yourapi
go mod edit -go="$(go version | awk '{print $3}' | sed 's/^go//')"   # match installed Go

# Runtime deps — always @latest, then tidy:
go get github.com/gin-gonic/gin@latest
go get github.com/jackc/pgx/v5@latest
go get github.com/oklog/ulid/v2@latest
go get github.com/golang-jwt/jwt/v5@latest
go get github.com/MicahParks/keyfunc/v3@latest
go get github.com/go-playground/validator/v10@latest
go get github.com/stretchr/testify@latest
go get github.com/testcontainers/testcontainers-go/modules/postgres@latest
go mod tidy
go list -m -u all            # review available upgrades & majors before committing
```

The import path encodes the **major** version (`pgx/v5`, `jwt/v5`, `keyfunc/v3`). When you `@latest`, confirm you are on
the major you intend — a new major is a new import path, not a transparent upgrade.

### Track dev tools as `tool` directives

Go 1.24+ records executable dependencies in `go.mod`, so the toolchain versions with the module and CI needs no separate
install step:

```bash
go get -tool github.com/sqlc-dev/sqlc/cmd/sqlc@latest
go get -tool github.com/pressly/goose/v3/cmd/goose@latest
go get -tool mvdan.cc/gofumpt@latest
go get -tool github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
```

Run them through the module: `go tool sqlc generate`, `go tool goose …`, `go tool gofumpt -l .`,
`go tool golangci-lint run`. (`golangci-lint` is large; some teams prefer the official CI action instead of a tool
directive — either is fine, just keep it reproducible.)

## golangci-lint v2 config

`.golangci.yml` — start from the `standard` set and add high-signal linters:

```yaml
version: "2"
run:
    timeout: 5m
linters:
    default: standard # errcheck, govet, ineffassign, staticcheck, unused
    enable:
        - bodyclose # HTTP/SQL bodies must be closed
        - errorlint # correct errors.Is/As/%w usage
        - gocritic # opinionated correctness/style
        - gosec # security analysis
        - misspell
        - revive # configurable golint successor
        - unconvert # redundant conversions
    exclusions:
        rules:
            - path: _test\.go # relax security/errcheck noise in tests
              linters: [gosec, errcheck]
            - linters: [revive] # internal/ is not a public API surface
              text: "^exported:"
formatters:
    enable:
        - gofumpt
        - goimports
```

Use `gofumpt` (a stricter superset of `gofmt`) as the formatter; `gofumpt -l .` listing any file fails the gate.

## Makefile (the gate + codegen)

```make
SHELL := /bin/bash
DATABASE_URL ?= postgres://app:app@localhost:5432/app?sslmode=disable

.PHONY: gate fmt-check lint vet test
gate: fmt-check lint vet test
fmt-check: ; @out=$$(go tool gofumpt -l .); [ -z "$$out" ] || { echo "$$out"; exit 1; }
lint:  ; go tool golangci-lint run
vet:   ; go vet ./...
test:  ; go test -race ./...

.PHONY: sqlc sqlc-check migrate-up
sqlc:       ; go tool sqlc generate
sqlc-check: sqlc ; @git diff --exit-code -- internal/store/db || { echo "stale sqlc — run make sqlc"; exit 1; }
migrate-up: ; go tool goose -dir migrations postgres "$(DATABASE_URL)" up

.PHONY: build
build: ; CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o out/server ./cmd/server
```

`sqlc-check` (regenerate, then fail on a git diff) belongs in CI so generated code can never drift from the SQL.

## Dockerfile — multi-stage, static, distroless

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download              # cache deps separately from source
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/server /server
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

`CGO_ENABLED=0` produces a static binary that runs on `distroless/static` (no libc, no shell) — minimal attack surface.
Use the floating `golang:alpine` tag and let `GOTOOLCHAIN=auto` fetch the exact patch your `go.mod` declares, so the
image tracks the language version you actually target rather than a pinned one.

## Configuration from the environment (stdlib only)

```go
// Package config loads runtime configuration from the environment.
package config

import (
    "os"
    "strconv"
)

type Config struct {
    Port         string
    DatabaseURL  string
    AuthRequired bool
    AuthJWKSURL  string
    AuthIssuer   string
    AuthAudience string
    DBMaxConns   int32
}

func Load() Config {
    return Config{
        Port:         env("PORT", "8080"),
        DatabaseURL:  env("DATABASE_URL", "postgres://app:app@localhost:5432/app?sslmode=disable"),
        AuthRequired: env("AUTH_REQUIRED", "false") == "true",
        AuthJWKSURL:  env("AUTH_JWKS_URL", ""),
        AuthIssuer:   env("AUTH_ISSUER", ""),
        AuthAudience: env("AUTH_AUDIENCE", ""),
        DBMaxConns:   envInt32("DB_MAX_CONNS", 16),
    }
}

func env(key, def string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return def
}

func envInt32(key string, def int32) int32 {
    if v := os.Getenv(key); v != "" {
        if n, err := strconv.ParseInt(v, 10, 32); err == nil && n > 0 {
            return int32(n)
        }
    }
    return def
}
```

Twelve-factor: configuration is env vars with sane local defaults; secrets never live in code.

## Server wiring + graceful shutdown

`main` is tiny; `run` returns an error so `main` is just `os.Exit` plumbing. Migrate on boot, size the pool explicitly,
start background workers, then serve and drain on signal.

```go
func main() {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    slog.SetDefault(logger)
    if err := run(logger); err != nil {
        logger.Error("server exited", "error", err.Error())
        os.Exit(1)
    }
}

func run(logger *slog.Logger) error {
    cfg := config.Load()
    ctx := context.Background()

    if err := store.Migrate(ctx, cfg.DatabaseURL); err != nil { // goose up, embedded
        return err
    }
    poolCfg, err := pgxpool.ParseConfig(cfg.DatabaseURL)
    if err != nil {
        return err
    }
    poolCfg.MaxConns = cfg.DBMaxConns         // default (max(4,NumCPU)) is often too small
    poolCfg.MaxConnLifetime = time.Hour
    pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
    if err != nil {
        return err
    }
    defer pool.Close()

    authMW, err := auth.NewMiddleware(ctx, auth.Config{
        Required: cfg.AuthRequired, JWKSURL: cfg.AuthJWKSURL,
        Issuer: cfg.AuthIssuer, Audience: cfg.AuthAudience,
    })
    if err != nil {
        return err
    }

    app := &httpapi.App{Store: store.New(pool), Logger: logger, Auth: authMW}
    srv := &http.Server{
        Addr:              ":" + cfg.Port,
        Handler:           httpapi.NewRouter(app),
        ReadHeaderTimeout: 10 * time.Second, // mitigate Slowloris
    }

    serveErr := make(chan error, 1)
    go func() {
        if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
            serveErr <- err
        }
    }()

    sigCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer stop()
    select {
    case err := <-serveErr:
        return err
    case <-sigCtx.Done():
        logger.Info("shutdown signal received, draining")
    }

    shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    return srv.Shutdown(shutdownCtx) // stop accepting, finish in-flight, then return
}
```

Key points:

- **`ReadHeaderTimeout`** is mandatory — without it the server is exposed to slow-header DoS. Set read/write timeouts
  too unless you stream (SSE needs an unbounded write deadline).
- **Size the pool deliberately.** The pgx default is small; pick `MaxConns` from your concurrency target and Postgres'
  `max_connections`. Background listeners (SSE `LISTEN`) should use their **own** connection, not a pooled one.
- **Inject a clock** (`App.Now func() time.Time`) so tests are deterministic; default to `time.Now().UTC()`.
- **One clock, UTC everywhere.** Format timestamps RFC3339 UTC at the boundary; keep `time.Time` internally.
- Log with `slog` structured key/values; **do not write unit tests for logging** — assert behavior, not log lines.
