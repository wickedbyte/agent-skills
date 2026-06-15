# Ownership and Borrowing

The borrow-vs-own decision, ergonomic inputs (`AsRef`/`impl Into`/`Cow`), clone discipline, lifetimes and elision, and
escaping the `Rc<RefCell<T>>` trap.

Ownership is an API-level decision, not an afterthought. Write the signature from the answer to one question: _who owns
this value after the function returns?_ If the function only reads, it borrows. If it stores, moves, or consumes, it
takes ownership. The signature should make the cost — copy, allocate, move — visible to the caller.

## The borrow-vs-own decision

| You need to…                           | Take                                               | Not                                  |
| -------------------------------------- | -------------------------------------------------- | ------------------------------------ |
| Read a string                          | `&str`                                             | `&String`, `String`                  |
| Read a sequence                        | `&[T]`                                             | `&Vec<T>`, `Vec<T>`                  |
| Mutate a sequence in place             | `&mut [T]` (or `&mut Vec<T>` only if you push/pop) | `Vec<T>`                             |
| Read a filesystem path                 | `&Path` or `impl AsRef<Path>`                      | `&PathBuf`, `PathBuf`                |
| Store the value in a struct/collection | owned (`String`, `Vec<T>`)                         | a borrow tied to a caller's lifetime |
| Consume/transform the value            | owned                                              | `&T` then clone inside               |
| Return freshly produced data           | owned (`String`, `Vec<T>`)                         | a borrow you do not have             |

```rust
// ❌ Forces every caller to hand over ownership (and often clone) just to read
fn count_words(text: String) -> usize {
    text.split_whitespace().count()
}
```

```rust
// ✅ Borrows; the caller keeps their String and decides about copies
fn count_words(text: &str) -> usize {
    text.split_whitespace().count()
}
```

WHY: `&str` accepts `&String`, `&str`, string literals, and slices of larger strings with zero allocation. `&[T]`
accepts `&Vec<T>`, arrays, and sub-slices. Taking the concrete owned container narrows what callers can pass _and_
usually pushes a clone onto them. Borrowing leaves the copy decision where it belongs — with the caller who knows
whether they still need the value.

## Ergonomic inputs: `impl Into`, `impl AsRef`, `Cow`

| Pattern                   | Use when                                                               |
| ------------------------- | ---------------------------------------------------------------------- |
| `name: impl Into<String>` | You will **store** the value owned; caller may pass `&str` or `String` |
| `path: impl AsRef<Path>`  | You only **borrow** for the call; the std-library idiom for paths      |
| `Cow<'a, str>`            | A function usually borrows but _sometimes_ must allocate (return type) |

```rust
// ✅ Stores an owned String, but callers pass whatever they have
fn new(name: impl Into<String>) -> Config {
    Config { name: name.into() }
}

// ✅ Cow: borrow when nothing changed, allocate only when we actually edit
use std::borrow::Cow;

fn normalize(input: &str) -> Cow<'_, str> {
    if input.contains(' ') {
        Cow::Owned(input.replace(' ', "_"))
    } else {
        Cow::Borrowed(input)
    }
}
```

WHY: `impl Into<String>` is right when ownership is the destination — it absorbs the conversion at the boundary so the
body holds a clean `String`. `impl AsRef<Path>` is right when you merely pass the borrow through to `std::fs`. `Cow`
earns its keep when the common path is borrow-only but a rare path must allocate: callers of `normalize` pay nothing
for the no-space case.

## Clone discipline — a borrow-checker `.clone()` is a design smell

A `.clone()` added to silence the borrow checker is a signal to rethink ownership, not a fix. The cost is real and now
invisible in the type.

```rust
// ❌ Clone to dodge a borrow conflict
fn process(items: &mut Vec<Item>, config: &Config) {
    let snapshot = items.clone(); // "the borrow checker made me"
    for item in &snapshot {
        items.push(transform(item, config));
    }
}
```

```rust
// ✅ Compute the new items first, then extend — no clone, no aliasing
fn process(items: &mut Vec<Item>, config: &Config) {
    let new: Vec<Item> = items.iter().map(|it| transform(it, config)).collect();
    items.extend(new);
}
```

Before reaching for `.clone()`, try in order:

1. **Borrow instead of own** — does the callee actually need ownership, or just `&T`?
2. **Split borrows** — borrow distinct struct fields separately so the checker sees they do not alias.
3. **Restructure** — compute into a local, then mutate; or narrow a borrow's scope so it ends sooner (NLL).
4. **Move once** — if a value is used in exactly one place afterward, pass it by value rather than cloning.

A clone is legitimate when you genuinely need two independent owned copies, when the value is `Copy` (then it is not
really a clone), or when the type is cheap (`Arc::clone` bumps a refcount). The smell is the _reflexive_ clone that
papers over a fight.

## Lifetimes and elision

Let elision do the work. Name a lifetime only when a returned borrow is tied to one specific input among several.

```rust
// ✅ Elided — the compiler infers the obvious single-input relationship
fn first_word(s: &str) -> &str {
    s.split_whitespace().next().unwrap_or("")
}
```

```rust
// ✅ Named — the return ties to `haystack`, not `needle`, so it must be explicit
fn find<'h>(haystack: &'h str, needle: &str) -> Option<&'h str> {
    haystack.find(needle).map(|i| &haystack[i..])
}
```

```rust
// ❌ Annotating a relationship elision already handles — noise, not rigor
fn first_word<'a>(s: &'a str) -> &'a str {
    s.split_whitespace().next().unwrap_or("")
}
```

WHY: the three elision rules cover the overwhelming majority of signatures. An explicit `'a` is signal: it tells the
reader "this output borrows _that_ input." Spraying `'a` everywhere drowns that signal and reads as ceremony.

## Escaping the `Rc<RefCell<T>>` trap

`Rc<RefCell<T>>` reached for reflexively is the single most common way to dodge thinking about ownership. It moves
borrow checking to runtime (`RefCell` panics on aliased borrows) and shared-mutable state to a place the compiler can
no longer help you. Prefer, in order:

| Situation                                            | Reach for                                                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Clear parent-owns-child hierarchy                    | An ownership **tree** — `struct Parent { children: Vec<Child> }`                     |
| Graph-shaped data, nodes reference each other        | **Indices/handles** into a `Vec` or arena (`NodeId(usize)`), not pointers            |
| A function needs to mutate something it does not own | Thread `&mut T` through the call                                                     |
| Genuinely shared _immutable_ data                    | `Rc<T>` (or `Arc<T>` across threads) — no `RefCell`                                  |
| Genuinely shared _mutable_ graph (no clean tree)     | `Rc<RefCell<T>>` (single-thread) / `Arc<Mutex<T>>` (multi-thread) — and document why |

```rust
// ✅ Arena + indices instead of Rc<RefCell<Node>> for a graph
struct Graph {
    nodes: Vec<NodeData>,
    edges: Vec<(NodeId, NodeId)>,
}

#[derive(Clone, Copy)]
struct NodeId(usize);

struct NodeData {
    label: String,
}

impl Graph {
    fn neighbors(&self, id: NodeId) -> impl Iterator<Item = NodeId> + '_ {
        self.edges
            .iter()
            .filter(move |(from, _)| from.0 == id.0)
            .map(|(_, to)| *to)
    }
}
```

WHY: the arena owns every node in one `Vec`; a `NodeId` is a plain `Copy` index, so cycles and shared references become
trivial integers the borrow checker is happy with. You trade pointer-chasing for index lookups (often _faster_ due to
locality) and you regain compile-time borrow checking. Genuine shared-mutable graphs — a GUI widget tree with
back-edges, say — do warrant `Rc<RefCell>`; the rule is that it should be a _considered_ choice with a comment, not the
first thing you type.

## Interior mutability — when it is actually warranted

Interior mutability (`Cell`, `RefCell`, `Mutex`, atomics) lets you mutate through a shared `&` reference. Use it only
when the data model genuinely requires shared mutation — not to avoid threading `&mut`.

| Type                     | Use when                                                                            |
| ------------------------ | ----------------------------------------------------------------------------------- |
| `Cell<T>`                | `Copy` values; cheap get/set with no borrowing (counters, flags)                    |
| `RefCell<T>`             | Non-`Copy` values, single-threaded; runtime-checked borrows                         |
| `Mutex<T>` / `RwLock<T>` | Shared mutation across threads (usually behind `Arc`)                               |
| `AtomicUsize` etc.       | Lock-free counters/flags; pick the weakest correct `Ordering` (`Relaxed` for stats) |

WHY: each of these moves a guarantee from compile time to run time, so each is a small surrender of the borrow
checker's help. `Cell` is the cheapest (no borrow tracking at all) and `RefCell` the next; both _panic_ on misuse, so a
`RefCell` in hot or hard-to-test code is a latent crash. Reach for them when a legitimate design — a memoization cache,
an observer that mutates on notify — needs shared mutation, and keep the scope of the borrow or lock as small as
possible.
