# Unsafe and FFI

`unsafe` is a last-mile tool, not a design strategy. Start in safe Rust; introduce `unsafe` only with a concrete reason;
keep the block tiny; write a `// SAFETY:` comment for the invariant; and wrap it in a safe API so callers never hold the
proof obligation.

## What `unsafe` actually unlocks

`unsafe` does not turn off the borrow checker or the type system. It only lets you do five things the compiler cannot
verify:

1. Dereference a raw pointer (`*const T` / `*mut T`).
2. Call an `unsafe` function (including FFI).
3. Access or modify a mutable `static`.
4. Implement an `unsafe` trait (`Send`, `Sync`, …).
5. Access the fields of a `union`.

Everything else inside an `unsafe` block is still checked normally. So the goal is to isolate exactly the one of these
five operations you need, prove its precondition, and let safe Rust enforce the rest.

## Keep the block tiny and state the invariant

An `unsafe` block should span one logical operation, with a `// SAFETY:` comment directly above stating the invariant
that makes it sound.

```rust
use core::slice;

// ✅ one scoped operation, invariant stated, safe signature
fn as_bytes(words: &[u32]) -> &[u8] {
    let len = core::mem::size_of_val(words);
    // SAFETY: `u32` is plain data with no padding/uninit; `len` is the exact byte length of
    // the same allocation, and the returned slice borrows `words`, so it cannot outlive it.
    unsafe { slice::from_raw_parts(words.as_ptr().cast::<u8>(), len) }
}
```

```rust
// ❌ an unsafe fn that exports raw pointer + length + lifetime onto every caller
pub unsafe fn as_bytes<'a>(ptr: *const u32, len: usize) -> &'a [u8] {
    unsafe { slice::from_raw_parts(ptr.cast::<u8>(), len * 4) }
}
```

WHY: the safe wrapper _contains_ the validity, alignment, and lifetime reasoning in one audited place. The `unsafe fn`
version pushes all three obligations onto every call site, multiplying the surface where a mistake can introduce UB.

## Expose a safe wrapper around unsafe internals

The standard pattern: a public safe function checks the preconditions, then performs one tightly-scoped `unsafe`
operation. Callers get a totally safe API; the proof lives in your crate.

```rust
pub fn first(slice: &[u32]) -> Option<&u32> {
    if slice.is_empty() {
        return None;
    }
    // SAFETY: the early return guarantees the slice has at least one element.
    Some(unsafe { slice.get_unchecked(0) })
}
```

Document the invariant **on the type or function**, not only at the block, so future maintainers know what must hold.

## `unsafe_op_in_unsafe_fn` — deny it

Edition 2024 no longer treats the body of an `unsafe fn` as an implicit `unsafe` block. Enable the lint at deny level so
every unsafe operation is explicitly bracketed even inside an `unsafe fn` — this forces a `// SAFETY:` comment at each
real hazard rather than one blanket waiver for the whole function.

```toml
[lints.rust]
unsafe_op_in_unsafe_fn = "deny"
```

```rust
// ✅ each hazardous op is its own block, even inside an unsafe fn
pub unsafe fn read_two(p: *const u8) -> (u8, u8) {
    // SAFETY: caller guarantees `p` and `p.add(1)` are valid, aligned, initialized reads.
    let a = unsafe { *p };
    let b = unsafe { *p.add(1) };
    (a, b)
}
```

## `#[repr(C)]` and `#[repr(transparent)]` for layout and FFI

Rust's default layout is unspecified — the compiler may reorder fields. For FFI, transmutes, or any place layout is a
_contract_, make it explicit.

| Repr                           | Use for                                                                        |
| ------------------------------ | ------------------------------------------------------------------------------ |
| `#[repr(C)]`                   | a struct/enum/union that crosses an FFI boundary or is read by other languages |
| `#[repr(transparent)]`         | a newtype wrapping a single field that must keep the inner type's exact ABI    |
| `#[repr(u8)]` / `#[repr(i32)]` | a fieldless enum with a fixed discriminant size for FFI                        |

```rust
#[repr(C)]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct Header {
    len: u32,
    kind: u16,
    flags: u16,
}
```

Keep FFI types as plain data (`#[repr(C)]` POD) and convert into richer Rust types immediately at the boundary, so the
rest of the code works with safe, idiomatic types.

## Edition 2024: `unsafe extern` and `#[unsafe(no_mangle)]`

Edition 2024 changed the FFI syntax. Extern blocks declaring foreign functions are now `unsafe extern`, and the
attributes that affect linkage/symbol safety move inside an `unsafe(...)` wrapper.

```rust
// ✅ edition 2024
unsafe extern "C" {
    // declaring the signature is the unsafe act; calling still needs its own unsafe block
    fn strlen(s: *const core::ffi::c_char) -> usize;
}

#[unsafe(no_mangle)]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

`#[no_mangle]` → `#[unsafe(no_mangle)]`; `#[export_name = "..."]` and `#[link_section = "..."]` likewise move inside
`unsafe(...)`. Note too that edition 2024 made `std::env::set_var` / `remove_var` `unsafe` (they are not thread-safe),
so
any var-mutation now needs an `unsafe` block with a SAFETY note about no concurrent access.

## Never unwind across an FFI boundary

A Rust panic unwinding across an `extern "C"` frame into C is undefined behavior. Any `extern "C"` function whose body
can panic must catch the unwind and convert it to an error/abort at the boundary.

```rust
use std::panic::{catch_unwind, AssertUnwindSafe};

#[unsafe(no_mangle)]
pub extern "C" fn process(ptr: *const u8, len: usize) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: caller guarantees `ptr` is valid for `len` bytes for the call's duration.
        let data = unsafe { core::slice::from_raw_parts(ptr, len) };
        do_work(data)
    }));
    match result {
        Ok(code) => code,
        Err(_) => -1, // turn the panic into an error code instead of unwinding into C
    }
}
```

WHY: the C ABI has no concept of unwinding; letting a panic cross it is instant UB. `catch_unwind` at the boundary (or
`panic = "abort"`, which aborts instead of unwinding) is the only sound choice. The newer `extern "C-unwind"` ABI exists
for the rare case where unwinding _is_ meant to propagate — do not use it unless that is the explicit contract.

## Pointer provenance

A raw pointer carries _provenance_ — the permission to access a particular allocation — not just an address. Do not
fabricate a pointer by casting an integer to a pointer and dereferencing it; derive pointers from references or from
`Box`/`Vec` you own. Use `ptr.add`/`ptr.offset` to move within an allocation (with the same provenance), and prefer the
strict-provenance helpers (`ptr.addr()`, `ptr::with_addr`) over `as` casts when you must round-trip through an integer.
Miri checks provenance violations that compile and run fine on hardware.

## Verify: Miri, sanitizers

Compiling and running clean proves nothing about UB. Validate unsafe/FFI/pointer code with the tools built for it.

```bash
# Miri — interprets the program, catches UB, aliasing, and uninitialized reads
rustup +nightly component add miri
cargo +nightly miri test

# AddressSanitizer — runtime memory errors (use-after-free, OOB) on instrumented code
RUSTFLAGS=-Zsanitizer=address \
cargo +nightly test -Zbuild-std --target x86_64-unknown-linux-gnu

# ThreadSanitizer — data races
RUSTFLAGS=-Zsanitizer=thread \
cargo +nightly test -Zbuild-std --target x86_64-unknown-linux-gnu
```

WHY each: Miri is a semantic interpreter — slow, but it catches aliasing and provenance violations that pass on real
hardware. Sanitizers run instrumented native code, catching memory and concurrency bugs on realistic workloads, but
need nightly + `-Zbuild-std`. They are complementary; run Miri on any pointer/layout change and add a sanitizer lane for
concurrent unsafe code. Note TSan cannot see atomic-fence or inline-asm synchronization, so curate that lane rather than
trusting it blindly.

## Minimize the surface

The senior move is to have _less_ `unsafe`, documented better. Push it into the smallest leaf module, wrap it in a safe
API, write the invariants on the type, and gate it in CI with Miri. If a crate is meant to contain no `unsafe` at all,
enforce it with `#![forbid(unsafe_code)]` (or `unsafe_code = "forbid"` in `[lints.rust]`).
