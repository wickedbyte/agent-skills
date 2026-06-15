# Security

Validate at the trust boundary, then trust your own types inside it. Most Python security holes are a handful of
recurring mistakes — `assert` as a check, `eval`/`pickle` on untrusted input, string-built SQL/shell, `==` on secrets.
Each has a one-line fix.

## Never `assert` for runtime or security checks

`python -O` **strips every `assert`** (and `-OO` also drops docstrings). An assertion used as a real check vanishes in
any optimized deployment — the validation you thought protected the system is simply gone. `assert` is for documenting
invariants you believe can never be false, not for guarding input or permissions.

```python
# ❌ Disappears under -O; the check is not there in production
def authorize(user: User) -> None:
    assert user.is_admin, "must be admin"

# ✅ Always runs; raises a specific exception
def authorize(user: User) -> None:
    if not user.is_admin:
        raise PermissionError("admin privileges required")
```

Raise a specific subclass of the right built-in (`ValueError`, `PermissionError`, `LookupError`) so callers can catch it
narrowly.

## Tokens and constant-time comparison

Generate secrets with the `secrets` module, never `random` — `random` is a deterministic PRNG seeded predictably and is
not cryptographically secure. Compare secret material with `hmac.compare_digest`, which takes constant time regardless
of where the first differing byte falls; plain `==` short-circuits and leaks length/prefix information through timing.

```python
# ❌ random is predictable; == leaks timing
import random
token = "".join(random.choices("0123456789abcdef", k=32))
def check(supplied: str, expected: str) -> bool:
    return supplied == expected

# ✅ CSPRNG token; constant-time comparison
import secrets, hmac
token = secrets.token_hex(32)
def check(supplied: str, expected: str) -> bool:
    return hmac.compare_digest(supplied, expected)
```

Use `secrets.token_urlsafe` / `token_hex` / `token_bytes` for session IDs, reset tokens, and API keys.

## Parsing: `ast.literal_eval`, never `eval`/`exec` on untrusted input

`eval`/`exec` execute arbitrary code — a string from a user, a file, or the network becomes remote code execution. To
parse a Python _literal_ (number, string, tuple, list, dict, bool, `None`), use `ast.literal_eval`, which evaluates only
literal structures and nothing else.

```python
# ❌ Arbitrary code execution
config = eval(untrusted_text)

# ✅ Only literals are accepted; anything else raises
import ast
config = ast.literal_eval(untrusted_text)
```

For structured data, prefer a real format parser — `json.loads`, `tomllib.load` — over evaluating Python.

## Deserialization: never `pickle` or `yaml.load` untrusted data

`pickle.loads` and `yaml.load` (the unsafe default loader) can construct arbitrary objects and run code during
unpickling — loading attacker-controlled bytes is equivalent to running attacker code. Use a data-only format for any
input you do not fully control.

```python
# ❌ Code execution on load
import pickle, yaml
obj = pickle.loads(untrusted_bytes)
cfg = yaml.load(untrusted_text)             # unsafe loader

# ✅ Data-only parsers
import json, yaml
obj = json.loads(untrusted_text)
cfg = yaml.safe_load(untrusted_text)        # constructs only basic types
```

Reserve `pickle` for trusted, internal, same-version data you produced yourself. The same caution applies to
decompressing untrusted input — bound the output size to avoid a decompression bomb (see `strings-and-io.md`).

## TLS: `ssl.create_default_context`

Create TLS contexts with `ssl.create_default_context()` and reuse one context across connections. It enables
certificate verification and hostname checking with sane modern defaults. Hand-assembling an `SSLContext` almost always
ends with verification accidentally disabled.

```python
# ❌ Disables the protection TLS exists to provide
import ssl
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

# ✅ Secure defaults, verification on
import ssl
ctx = ssl.create_default_context()          # build once, reuse for many connections
```

## Subprocess: argument lists, never `shell=True`

`subprocess` with `shell=True` runs the command through the shell, so any interpolated value can inject extra commands.
Pass an **argument list** with `shell=False` (the default) — the args go straight to `execve`, the shell never parses
them, and injection is impossible.

```python
# ❌ Shell injection: filename = "x; rm -rf /"
import subprocess
subprocess.run(f"convert {filename} out.png", shell=True)

# ✅ Args passed directly; no shell parsing
import subprocess
subprocess.run(["convert", filename, "out.png"], check=True)
```

If you truly need shell features, quote every interpolated value with `shlex.quote` — but prefer the arg-list form,
which removes the question entirely.

## Injection: t-strings or parameterized queries

Never build SQL, HTML, or shell strings by interpolating untrusted values with an f-string. Use the mechanism that
keeps the value _out of the syntax_: DB-API parameters for SQL, an escaping template layer for HTML, an arg list for
shell. 3.14 t-strings (PEP 750) give a clean injection-safe processing layer for each — see `strings-and-io.md` for the
processor pattern.

```python
# ❌ SQL injection
cursor.execute(f"SELECT * FROM users WHERE email = '{email}'")

# ✅ The driver binds the value; it is never parsed as SQL
cursor.execute("SELECT * FROM users WHERE email = %s", (email,))
```

## Path traversal: validate untrusted paths

A user-supplied filename like `../../etc/passwd` escapes the directory you intended. Resolve the path and confirm it
stays inside the allowed root before opening it.

```python
from pathlib import Path

def safe_open(root: Path, user_path: str) -> Path:
    candidate = (root / user_path).resolve()
    if not candidate.is_relative_to(root.resolve()):
        raise ValueError(f"path escapes allowed root: {user_path!r}")
    return candidate
```

`resolve()` collapses `..` and symlinks; `is_relative_to` (3.9+) is the containment check. Do this for every path that
originates outside your code.

## Do not log secrets

Logging is a persistent, often centrally-aggregated record. Never write tokens, passwords, full authorization headers,
or complete request bodies to it — log the _fact_ and a non-sensitive identifier instead.

```python
# ❌ Secret lands in the log forever
logger.info("authenticated with token %s", token)

# ✅ Log the event and a safe identifier
logger.info("authenticated user_id=%s", user.id)
```

Redact at the boundary (a logging filter that strips known secret fields) so a future `logger.debug(payload)` cannot
leak by accident.

## Other hardening defaults

- Keep **hash randomization on** (the default). It protects `dict`/`set` against crafted worst-case collision inputs.
  Only fix `PYTHONHASHSEED` for benchmarks or tests, never as an operational setting.
- Prefer `-I` (isolated) or `-P` (ignore `sys.path[0]`) for operational entry points to reduce accidental code
  injection via the import path — documented flags, not bootstrap hacks.
- Pay the validation cost **once at the edge** (parse untrusted input into typed objects there), then keep inner loops
  free of defensive re-checking. Rigor and performance pull the same direction.
