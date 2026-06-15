# Error Handling

Errors as values: `Result`/`Option` and `?`, the `unwrap`/`expect` policy, `thiserror` for libraries, `anyhow` for
applications, and the panic-vs-recoverable line.

Rust has no exceptions. A failure that a caller might recover from is a _value_ — `Result<T, E>` for "succeeded or
failed
with a reason", `Option<T>` for "present or absent" — and you move it up the stack with `?`. A failure that means the
program's assumptions are broken is a _panic_. Getting the line between those two right is most of error handling.

## `Result`, `Option`, and `?`

```rust
// ✅ Absence is Option; recoverable failure is Result; ? threads both up
fn first_line(text: &str) -> Option<&str> {
    text.lines().next()
}

fn load_port(raw: &str) -> Result<u16, ParsePortError> {
    let port: u16 = raw.parse().map_err(|_| ParsePortError::NotANumber)?;
    if port == 0 {
        return Err(ParsePortError::OutOfRange);
    }
    Ok(port)
}
```

WHY: `?` is early-return-on-error compressed to one character — on `Err`/`None` it returns, on `Ok`/`Some` it unwraps.
It composes failure handling into linear, readable code without the `match`-pyramid. The only requirement is that the
error type at the `?` site converts (via `From`) into the function's error type — which is exactly what the
`thiserror`/`anyhow` machinery below provides.

## The `unwrap` / `expect` policy

| Context                           | Policy                                                                          |
| --------------------------------- | ------------------------------------------------------------------------------- |
| Library code paths                | **Forbidden.** Return `Result`/`Option` and propagate with `?`                  |
| Provably-impossible internal case | Acceptable with `expect("invariant: …")` stating _why_ it cannot fail           |
| Tests, examples, benchmarks       | Fine — a panic _is_ the failure signal                                          |
| A binary's startup/setup          | `expect("config must load")` with a useful message is a deliberate crash policy |

```rust
// ❌ unwrap as control flow in a library
pub fn get(&self, id: &str) -> Item {
    self.map.get(id).unwrap().clone()
}
```

```rust
// ✅ Return the absence; let the caller decide
pub fn get(&self, id: &str) -> Option<&Item> {
    self.map.get(id)
}
```

```rust
// ✅ expect at a binary's edge, where crashing with a message is the policy
fn main() {
    let config = Config::load().expect("config.toml must be present and valid");
    run(config);
}
```

WHY: a bare `.unwrap()` in a library turns the caller's recoverable situation into a process abort they cannot
intercept. `.expect("msg")` is strictly better than `.unwrap()` when a panic is genuinely warranted, because the
message documents the invariant and shows up in the panic output. The lint `clippy::unwrap_used` / `clippy::expect_used`
exists to enforce this; allow it in `#[cfg(test)]` modules, deny it in shipping code.

## `thiserror` for libraries

A library exposes a _typed_ error enum so callers can `match` on the failure mode. Derive `thiserror::Error` — it
generates the `Display` and `Error` impls, wires up `#[source]` chains, and gives you `#[from]` conversions for free.
**Do not hand-write `Display`** as the corpus's older examples do; the derive is the modern idiom and removes a whole
class of formatting bugs.

```rust
#[derive(thiserror::Error, Debug)]
pub enum ConfigError {
    #[error("no config found at {path}")]
    NotFound { path: String },

    // #[from] generates `From<std::io::Error>` so `?` converts automatically;
    // #[source] preserves the underlying cause for the error chain.
    #[error("failed to read config at {path}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },

    // #[from] on a single-field variant: the simplest auto-conversion.
    #[error("invalid TOML")]
    Parse(#[from] toml::de::Error),

    // transparent: delegate Display and source straight to the inner error.
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

fn read(path: &str) -> Result<String, ConfigError> {
    std::fs::read_to_string(path).map_err(|source| ConfigError::Io {
        path: path.to_string(),
        source,
    })
}
```

WHY: callers of a library need to _distinguish_ failures — retry on `Io`, report `NotFound` to the user, give up on
`Parse`. A typed enum makes that an exhaustive `match`; a stringly-typed error makes it substring-sniffing. `#[from]`
lets `?` convert foreign errors at the boundary, `#[source]` builds the chain that `{:?}` and error-reporting tools
walk,
and `#[error(transparent)]` forwards a wrapped error without adding a layer.

## `anyhow` for applications

An application (a binary, a CLI, a service `main`) usually does not need callers to match on its errors — it needs to
propagate richly and report at the top. `anyhow::Result<T>` is a boxed, any-error type; `.context(...)` adds a
human-readable layer at each boundary; `bail!`/`ensure!` are early-return shorthands.

```rust
use anyhow::{bail, ensure, Context, Result};

fn run(path: &str) -> Result<()> {
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("reading config from {path}"))?;

    ensure!(!raw.is_empty(), "config at {path} is empty");

    let port: u16 = raw.trim().parse().context("parsing port")?;
    if port < 1024 {
        bail!("port {port} is privileged");
    }
    Ok(())
}
```

WHY: in an application the next thing up the stack is usually `main`, which prints and exits. `anyhow` optimizes for
that:
`?` accepts _any_ error, `.context()` builds a readable chain ("parsing port: invalid digit") instead of a bare leaf
error, and `bail!`/`ensure!` keep the happy path uncluttered. The rule of thumb: **`thiserror` when something matches on
your errors, `anyhow` when only humans read them.** A binary that wraps a library is the common case — the library
returns its `thiserror` enum, the binary adds `.context()` and lets `anyhow` carry it.

## Never `Result<T, String>` in a lasting API

```rust
// ❌ Stringly-typed error — callers can only substring-match
fn parse(raw: &str) -> Result<Config, String> {
    raw.parse().map_err(|e| format!("bad config: {e}"))
}
```

```rust
// ✅ A typed error callers can match on (or anyhow if it's an app)
fn parse(raw: &str) -> Result<Config, ConfigError> {
    raw.parse().map_err(ConfigError::from)
}
```

WHY: `Result<T, String>` throws away every distinction between failures and forces callers into fragile string
matching. It is acceptable in a throwaway prototype or a `main` that immediately prints — but the moment the function
outlives that, the `String` is technical debt. Promote it to a `thiserror` enum (library) or `anyhow::Error`
(application).

## Panic vs. recoverable: where the line is

| Failure                                                         | Mechanism                                                  |
| --------------------------------------------------------------- | ---------------------------------------------------------- |
| A broken internal invariant ("this index is always valid here") | `panic!` / `unreachable!` / `expect` — it is a bug         |
| Out-of-bounds slice index, integer overflow in debug            | Panic (the language's choice) — a bug to fix, not to catch |
| A user passed bad input                                         | `Result` — expected, recoverable                           |
| A network/file/parse operation failed                           | `Result` — expected, recoverable                           |
| A precondition the _type system_ should have guaranteed         | `panic!` (or better: make it unrepresentable)              |

```rust
// ✅ Panic for a true invariant violation — a bug, not a runtime condition
fn split_at_midpoint(s: &[u8]) -> (&[u8], &[u8]) {
    assert!(!s.is_empty(), "split_at_midpoint requires a non-empty slice");
    s.split_at(s.len() / 2)
}
```

WHY: a panic says "the programmer's assumptions were wrong" — it is a bug report, and catching it (via
`catch_unwind`) is almost always the wrong response. A `Result` says "the world did not cooperate" — the network was
down, the input was malformed — which is _expected_ and the caller has a legitimate way to handle. Ask the corpus's
question: _can the caller reasonably recover?_ If yes, `Result`. If no, panic and fix the bug.

## Error enums vs. boxed errors, and converting at boundaries

- **Enum** (`thiserror`) when callers benefit from matching specific variants, and when the set of failures is known and
  meaningful. This is the default for a library's public error.
- **Boxed** (`anyhow::Error`, or `Box<dyn std::error::Error + Send + Sync>`) when the failure is opaque to callers and
  you
  just need to propagate and report. Default for application code and internal plumbing.

Convert _at the boundary_ with `From`: implement `From<LowLevelError> for MyError` (or let `#[from]` generate it) so `?`
upgrades a dependency's error into your domain's error exactly where it crosses into your module.

```rust
// ✅ The ? operator converts io::Error -> ConfigError at the boundary via #[from]
fn open(path: &str) -> Result<File, ConfigError> {
    let file = File::open(path)?; // io::Error -> ConfigError::Parse? no — needs #[from] io::Error
    Ok(file)
}
```

WHY: converting at the boundary keeps each layer speaking its own error vocabulary. The filesystem layer returns
`io::Error`; the moment it enters your config module, `?` lifts it into `ConfigError` via the `From` impl, so callers of
the config module never see a raw `io::Error` leaking your implementation. `From` impls are also what make `?`
ergonomic — they are the glue between every layer's error type.
