# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog v2](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- best-practices-php — opinionated modern-PHP style guide targeting PHP 8.5 (strict_types, `final readonly` value
  objects, backed enums, `match`, exceptions named after the problem, constructor DI, PHPStan level max), with 10
  reference files.
- best-practices-python — opinionated Pythonic style guide targeting Python 3.14 (type-hints-everywhere with modern
  syntax, frozen dataclasses, Protocols, the enum family, EAFP, deferred annotations, uv + Ruff toolchain), with 9
  reference files.
- best-practices-rust — opinionated idiomatic-Rust style guide targeting Rust 1.96 / edition 2024 (illegal states
  unrepresentable, borrow-by-default, `Result`/`?`, `thiserror`/`anyhow`, small traits + generics, clippy-clean,
  scoped `unsafe`), with 10 reference files.
- go-gin-api — task skill for building well-structured, thoroughly tested REST/RPC HTTP APIs in idiomatic Go with Gin
  from an OpenAPI description (domain/store/httpapi layering, dependency selection with `@latest`/`tool` directives,
  Gin routing incl. resource-action RPC colon dispatch, strict request parsing + JSON error envelope, OAuth 2.0
  resource-server JWT/JWKS auth, pgx/sqlc/goose persistence with transactions + optimistic concurrency, SSE over
  `LISTEN/NOTIFY`, graceful shutdown, and OpenAPI route-coverage + schema-fuzz contract testing), with 7 reference
  files.
- rust-api-design — task skill for building well-structured, thoroughly tested REST/RPC HTTP APIs in idiomatic Rust
  (Axum 0.8+, Tokio, sqlx 0.8+), covering the cross-cutting skeleton so only the API's own business logic is left to
  write: crate layout and inward layering, dependency stack, routing incl. resource-action `{id}:command` RPC,
  strict serde DTOs and parsing, the single `AppError`/`IntoResponse` envelope, transactional sqlx persistence with
  optimistic concurrency, OAuth 2.0 / OIDC bearer-token validation, SSE via `LISTEN/NOTIFY`, OpenAPI contract
  testing, `oneshot` + `#[sqlx::test]` integration tests and Schemathesis, and the multi-stage Dockerfile. Pairs
  with best-practices-rust; pins no crate versions. With 11 reference files.
- nestjs-api — playbook for building well-structured, strictly-typed, thoroughly-tested REST/RPC APIs in NestJS 11 on
  the Fastify adapter, from an OpenAPI contract (project layout with a Nest-free domain core, Zod boundary validation,
  the resource-action colon-command routing pattern, event-sourced command/projection persistence, `LISTEN/NOTIFY`
  SSE, OAuth 2.0 / OIDC resource-server auth, a single error envelope, and emitted-≡-canonical + Schemathesis contract
  testing); builds on best-practices-typescript, with 12 reference files.

### Changed

### Deprecated

### Removed

### Fixed

### Security

## 0.1.0 - 2026-06-15

### Added

- Initial release with new skills:
    - best-practices-nextjs
    - best-practices-react
    - best-practices-typescript
    - brand-guidelines-page
    - php-rename-namespace

[Unreleased]: https://github.com/wickedbyte/agent-skills/compare/v0.1.0...HEAD
