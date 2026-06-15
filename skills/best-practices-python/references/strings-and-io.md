# Strings and I/O

Interpolation that gets _displayed_ vs. interpolation that gets _escaped_; `pathlib` over `os.path`; zero-copy and
buffered I/O; `logging` over `print`; stdlib `compression.zstd`.

## f-strings for display, t-strings for anything escaped

f-strings (`f"..."`) eagerly build a `str`. They are the right tool for messages, log text you assemble yourself, file
names, and any value destined straight for a human. They are the _wrong_ tool the moment the interpolated value lands in
a language with its own syntax — SQL, HTML, a shell command — because the value is already concatenated in before any
escaping layer can see the seams.

3.14 t-strings (PEP 750) close that gap. A `t"..."` literal does **not** produce a `str`; it produces a
`string.templatelib.Template` that keeps the static text and the interpolated values _separate_. A processing function
escapes each interpolation for its target language, then assembles the final string. The injection vector — an attacker
controlling a value that becomes syntax — is gone because the static and dynamic pieces never get blended before
escaping.

| Output destination                                      | Tool                                                  | Why                                      |
| ------------------------------------------------------- | ----------------------------------------------------- | ---------------------------------------- |
| Human-readable message, log line you format, debug repr | f-string                                              | Eager `str`, no escaping concern         |
| SQL query with parameters                               | t-string processor (or DB-API params)                 | Values escaped/bound, not concatenated   |
| HTML / XML                                              | t-string processor that HTML-escapes interpolations   | Prevents XSS                             |
| Shell command                                           | t-string processor that `shlex.quote`s interpolations | Prevents shell injection                 |
| Path assembly                                           | `pathlib.Path` (not interpolation at all)             | Correct separators, no injection of `..` |

t-strings are **not** a drop-in f-string replacement. Reach for them only where a processing layer must treat the
interpolated parts differently from the literal parts.

### A t-string processor sketch

A `Template` exposes `.strings` (the literal chunks), `.values`, and `.interpolations` (each an `Interpolation` with a
`.value`, `.expression`, `.conversion`, and `.format_spec`). You interleave the literal chunks with _escaped_ values:

```python
import html
from string.templatelib import Interpolation, Template

def render_html(template: Template) -> str:
    parts: list[str] = []
    for item in template:
        match item:
            case str() as static:
                parts.append(static)        # trusted literal text — emit as-is
            case Interpolation() as interp:
                parts.append(html.escape(str(interp.value)))  # untrusted — escape
    return "".join(template_iter for template_iter in parts)

name = "<script>alert(1)</script>"
markup = render_html(t"<h1>Hello {name}</h1>")
# -> "<h1>Hello &lt;script&gt;alert(1)&lt;/script&gt;</h1>"
```

For SQL, the same shape yields a parameterized query: emit a placeholder (`?` / `%s`) for each interpolation and collect
its `.value` into a params list, so the database driver — not string concatenation — binds the value.

```python
def to_sql(template: Template) -> tuple[str, list[object]]:
    query: list[str] = []
    params: list[object] = []
    for item in template:
        if isinstance(item, Interpolation):
            query.append("?")
            params.append(item.value)
        else:
            query.append(item)
    return "".join(query), params

sql, params = to_sql(t"SELECT * FROM users WHERE email = {email} AND active = {active}")
cursor.execute(sql, params)
```

The WHY: the value of `email` can be `"x'; DROP TABLE users; --"` and nothing breaks, because that string is never
parsed as SQL — it travels as a bound parameter. The literal `SELECT ... WHERE email = ?` is the only thing the SQL
parser sees as query text.

Do not hand-roll a processor when a vetted library ships one. Use the t-string adapter your DB driver, template engine,
or HTML library provides; write your own only for a DSL that has none.

## `pathlib.Path` over `os.path`

Build paths with `Path` and the `/` operator, not string concatenation or `os.path.join`. It is typed, OS-correct, and
exposes the filesystem operations as methods.

```python
# ❌ Stringly-typed, easy to double-separate, no methods
import os.path
config = os.path.join(base_dir, "conf", "app.toml")
if os.path.exists(config):
    text = open(config).read()

# ✅ Typed, composable, self-contained
from pathlib import Path
config = Path(base_dir) / "conf" / "app.toml"
if config.is_file():
    text = config.read_text(encoding="utf-8")
```

Use `Path.read_text` / `read_bytes` / `write_text` for whole-file convenience, `Path.iterdir` / `glob` / `rglob` for
traversal, and `Path.resolve()` plus an `is_relative_to` check when accepting an untrusted path (see `security.md`).

## Buffered, `readinto`, and zero-copy I/O

Binary files opened with `open(path, "rb")` are buffered by default — that is the right baseline. The cost to watch on
hot paths is _allocation_: `f.read(n)` allocates fresh `bytes` every call. For streaming copies, read into one reusable
buffer with `readinto` and slice it with a `memoryview` so no copy is made.

```python
# ❌ Allocates a new bytes object per chunk
def copy_stream(src, dst) -> None:
    while chunk := src.read(1 << 16):
        dst.write(chunk)

# ✅ One buffer reused for the whole transfer; memoryview slices without copying
def copy_stream(src, dst, bufsize: int = 1 << 20) -> None:
    buf = bytearray(bufsize)
    view = memoryview(buf)
    while n := src.readinto(buf):
        dst.write(view[:n])
```

For file-to-socket (or file-to-file) transfer, push the copy into the kernel with `os.sendfile` / `socket.sendfile` and
skip user space entirely:

```python
import socket
from pathlib import Path

def serve_file(path: Path, sock: socket.socket) -> None:
    with path.open("rb") as f:
        sock.sendfile(f)   # kernel-side copy, no per-chunk Python loop
```

For large files with random access or repeated scans, `mmap` maps the file into memory so you index it like a
`bytes`/`bytearray` without reading it all up front:

```python
import mmap
from pathlib import Path

def count_newlines(path: Path) -> int:
    with path.open("rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
        return mm[:].count(b"\n")
```

Use `mmap` for the access pattern, not as a reflex — for a single sequential pass, buffered `readinto` is simpler and
just as fast. (See `performance.md` for the `bytearray`/`memoryview` layout rationale.)

## `logging` over `print`

`print` writes one undifferentiated stream with no level, no timestamp, no structure, and no way to silence it in
production. Use the `logging` module: configure once at the entry point, get a module-level logger, and let levels and
handlers decide what surfaces.

```python
import logging

logger = logging.getLogger(__name__)

def configure() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
```

Pass interpolation arguments to the logging call — do **not** pre-format with an f-string. The `%`-style lazy form only
renders the message if the level is enabled, so a suppressed `DEBUG` log costs nothing:

```python
# ❌ f-string runs str() on every argument even when DEBUG is disabled
logger.debug(f"processed {len(rows)} rows for tenant {tenant!r}")

# ✅ Lazy — formatting happens only if the DEBUG level is active
logger.debug("processed %d rows for tenant %r", len(rows), tenant)
```

Use `logger.exception(...)` inside an `except` block to capture the traceback, and never log secrets (tokens,
passwords, full request bodies) — see `security.md`.

## Compression: stdlib `compression.zstd`

3.14 brings Zstandard into the standard library as `compression.zstd` (PEP 784), and wires it into `tarfile`,
`zipfile`, and `shutil`. Prefer it over a third-party `zstandard` dependency for new code: it ships with the
interpreter, supports streaming compression/decompression, and gives a strong ratio-vs-speed balance that beats `gzip`
for most pipelines.

```python
from compression import zstd
from pathlib import Path

def compress(src: Path, dst: Path, level: int = 10) -> None:
    with src.open("rb") as fin, zstd.open(dst, "wb", level=level) as fout:
        copy_stream(fin, fout)   # the readinto/memoryview helper above
```

`compression.zstd` reads/writes the standard `.zst` format and integrates with `shutil.make_archive` /
`shutil.unpack_archive`, so a whole-directory archive is one call rather than a custom loop. Treat decompression of
untrusted input with the same care as any deserialization — bound the output size to avoid a decompression bomb.
