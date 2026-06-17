# Bootstrap & Configuration

How to load configuration from the environment and wire + gracefully shut down the server.

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
