# Iterators and Control Flow

Iterator pipelines vs. loops, laziness and avoiding intermediate allocation, fallible `collect`, the `entry` API,
pattern-matching depth, `let-else`, and `if let` chains (1.95+).

Idiomatic Rust prefers an expressive iterator pipeline when the dataflow is direct and a plain loop when mutation or
control flow reads more clearly. The goal is _clarity first, hidden cost last_ — never contort a loop into a chain to
look functional, and never materialize a `Vec` mid-pipeline you do not need.

## Iterator pipelines vs. loops

| Use a pipeline (`map`/`filter`/`fold`/`scan`/`flat_map`) when…      | Use a `for` loop when…                                                      |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Transforming/filtering/reducing a sequence to a value or collection | Mutating external state across iterations                                   |
| The dataflow is the point and reads top-to-bottom                   | Control flow is non-linear (`break` with value, `continue`, early `return`) |
| Each step is a clean transformation                                 | Side effects (I/O, logging) are the body's purpose                          |

```rust
// ✅ Pipeline — the transformation is the whole story
fn sum_even(xs: &[u64]) -> u64 {
    xs.iter().copied().filter(|x| x % 2 == 0).sum()
}
```

```rust
// ✅ Loop — clearer for accumulating into a map with conditional logic
fn tally(events: &[Event]) -> HashMap<Kind, u32> {
    let mut counts = HashMap::new();
    for e in events {
        if e.is_relevant() {
            *counts.entry(e.kind).or_insert(0) += 1;
        }
    }
    counts
}
```

WHY: iterator adapters _fuse_ — `iter().filter().map().sum()` compiles to the same machine code as a hand-written loop,
so there is no performance reason to prefer the loop. Choose on readability: a chain shines when each step is a pure
transformation; a loop shines when the body mutates, branches, or does I/O. Do not rewrite a clear loop into a clever
`fold` with a tuple accumulator just to avoid `mut`.

## Laziness — do not materialize mid-pipeline

Iterators are lazy: nothing runs until a consuming method (`sum`, `collect`, `for`, `count`) pulls. A `collect` in the
_middle_ of a chain forces an allocation and a second pass for no reason.

```rust
// ❌ Intermediate Vec — allocates, then iterates it again
fn sum_even(xs: &[u64]) -> u64 {
    let evens: Vec<u64> = xs.iter().copied().filter(|x| x % 2 == 0).collect();
    evens.iter().sum()
}
```

```rust
// ✅ Stay lazy — one pass, no allocation
fn sum_even(xs: &[u64]) -> u64 {
    xs.iter().copied().filter(|x| x % 2 == 0).sum()
}
```

WHY: the lazy chain processes one element at a time and never allocates; the eager version builds a whole `Vec<u64>`
just to iterate it once more and throw it away. `collect` is for when you actually need _storage_ — to return the
collection, index into it, or iterate it multiple times — not as a punctuation mark between adapters.

## Fallible and keyed `collect`

`collect` is type-directed: the target type decides what it builds. Two high-value targets:

```rust
// ✅ Collect into Result<Vec<_>, E> — stops at the first Err, short-circuits
fn parse_all(raw: &[&str]) -> Result<Vec<u16>, std::num::ParseIntError> {
    raw.iter().map(|s| s.parse::<u16>()).collect()
}

// ✅ Collect into Option<Vec<_>> — None if any element is None
fn all_present(opts: &[Option<u8>]) -> Option<Vec<u8>> {
    opts.iter().copied().collect()
}

// ✅ Collect tuples into a HashMap
fn index(users: Vec<User>) -> HashMap<UserId, User> {
    users.into_iter().map(|u| (u.id, u)).collect()
}
```

WHY: collecting an iterator of `Result<T, E>` into `Result<Vec<T>, E>` is one of Rust's most useful tricks — it
short-circuits on the first `Err` and hands you either every value or the first failure, replacing a manual loop with an
early return. The same inversion works for `Option`. Collecting `(K, V)` tuples into a `HashMap` builds an index in one
expression.

## The `entry` API

Reaching into a map to insert-or-update without a double lookup is what `entry` is for.

```rust
// ❌ Two lookups (contains_key then get_mut/insert) and a clone of the key
if counts.contains_key(&key) {
    *counts.get_mut(&key).unwrap() += 1;
} else {
    counts.insert(key.clone(), 1);
}
```

```rust
// ✅ One lookup, no unwrap
*counts.entry(key).or_insert(0) += 1;

// ✅ or_insert_with for an expensive default
cache.entry(key).or_insert_with(|| expensive_default());
```

WHY: `entry` hashes and probes the map once and hands back a handle to the slot, so you avoid the redundant lookup _and_
the `unwrap` that the contains-then-get pattern forces. `or_insert_with` defers building the default so you do not pay
for it when the key already exists.

## Pattern matching depth

| Tool                | Use for                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| exhaustive `match`  | Any owned enum you control — the compiler proves you covered every case |
| `@` bindings        | Capture a value _and_ test its shape: `n @ 1..=9`                       |
| match guards (`if`) | A condition the pattern alone cannot express                            |
| or-patterns (`\|`)  | Several shapes, one arm: `Up \| Down`                                   |
| slice patterns      | Destructure arrays/slices: `[first, .., last]`, `[only]`, `[]`          |
| `matches!`          | A boolean test of shape without a full `match`                          |

```rust
fn classify(xs: &[i32]) -> &'static str {
    match xs {
        [] => "empty",
        [only] => "single",
        [first, .., last] if first == last => "palindrome-ish",
        _ => "many",
    }
}

fn describe(n: u32) -> String {
    match n {
        0 => "zero".to_string(),
        small @ 1..=9 => format!("digit {small}"),
        _ => "large".to_string(),
    }
}

// matches! for a one-shot shape test
let is_terminal = matches!(state, State::Done | State::Failed(_));
```

WHY: patterns encode state and exhaustiveness _in the code_. `@` bindings, guards, or-patterns, and slice patterns let
a single `match` express what would otherwise be nested `if`/`else` with manual indexing — and the compiler still
checks coverage. `matches!` is the right tool when you want only a `bool`, not a full dispatch.

## `let-else` for guard-style early return

Stable since 1.65. When a binding must succeed or the function bails, `let ... else { ... }` keeps the happy path
unindented; the `else` block must diverge (`return`, `break`, `continue`, or `panic!`).

```rust
// ❌ if-let with the real work nested inside, or an is_some/unwrap dance
fn handle(opt: Option<Config>) -> Result<(), Error> {
    if let Some(config) = opt {
        // ... entire function body indented one level ...
        Ok(())
    } else {
        Err(Error::Missing)
    }
}
```

```rust
// ✅ let-else: bind or bail, then continue at the top level
fn handle(opt: Option<Config>) -> Result<(), Error> {
    let Some(config) = opt else {
        return Err(Error::Missing);
    };
    // config is in scope here, un-indented
    use_config(&config);
    Ok(())
}
```

WHY: `let-else` is the idiomatic early-return for a fallible binding. It pulls the failure case out and to the side, so
the success path reads as a straight line instead of drifting rightward with each guard. The diverging `else` is checked
by the compiler — you cannot fall through.

## `if let` chains (stable ~1.95)

Edition 2024 / Rust ~1.95 stabilized chaining `if let` (and boolean conditions) with `&&`, so several refutable patterns
can be tested in one condition without nesting.

```rust
// ❌ Nested if-let pyramid
if let Some(user) = lookup(id) {
    if let Some(email) = user.email() {
        if email.is_verified() {
            notify(&email);
        }
    }
}
```

```rust
// ✅ if let chain — one condition, flat body
if let Some(user) = lookup(id)
    && let Some(email) = user.email()
    && email.is_verified()
{
    notify(&email);
}
```

WHY: before chains, every refutable binding meant another level of indentation; the chain flattens the pyramid into a
single readable condition where all the bindings are in scope in the body. Mix `let` patterns and plain `bool`
conditions freely with `&&`.

## When a catch-all `_ =>` hides a missed variant

```rust
// ❌ Catch-all on an owned enum you control — adding a variant silently routes here
match status {
    Status::Active => activate(),
    _ => {} // a new Status::Suspended would be silently ignored
}
```

```rust
// ✅ Exhaustive — adding Status::Suspended is now a compile error until handled
match status {
    Status::Active => activate(),
    Status::Inactive => {}
    Status::Pending => {}
}
```

WHY: the compiler's exhaustiveness check is one of Rust's best safety nets — but a `_ =>` wildcard switches it off. On
an
enum _you own and may extend_, prefer listing every variant so that adding one turns into a compile error at every
match site, exactly where you must decide what to do. Reserve `_ =>` for genuinely open sets: `#[non_exhaustive]` enums
from other crates (which _require_ it), integer ranges, and large enums where a default truly is the right behavior for
all remaining cases.
