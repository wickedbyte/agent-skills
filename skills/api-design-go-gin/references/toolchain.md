# Toolchain: Module Setup, Tools, Lint/Format & the Gate

**Detect and respect the project's runner first.** What follows is the greenfield default. In an existing project, use
whatever build and task runner it already has — if commands run through `docker` / `docker compose`, a `Makefile`/
`Taskfile`, a vendored toolchain, or a custom script, invoke the tools that way instead of calling them directly. The
named tools below are the starting point for a new service, never a reason to migrate a project off what it already uses.

How to initialize the module, pull current dependencies, track build/dev tools as `tool` directives, configure the
lint/format gate, and run the canonical verification gate.

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
