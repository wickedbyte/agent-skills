# Project and Tooling

One `src/` layout, one `pyproject.toml`, one fast Rust-based toolchain: **uv** to manage the project, **Ruff** to lint
and format, a strict type checker in CI, and pytest for tests. The toolchain is fast enough to run on every keystroke,
so there is no excuse for skipping it.

## `src/` layout

Put the package under `src/<package>/`, not at the repository root. The `src/` layout forces you to install the package
(editable) to import it, so your tests run against the _installed_ package — the same thing your users get — and cannot
accidentally import from the working directory. It also keeps the repo root clean for config, CI, and docs.

```
my_project/
├── pyproject.toml
├── uv.lock
├── README.md
├── src/
│   └── my_project/
│       ├── __init__.py
│       └── core.py
└── tests/
    └── test_core.py
```

No `setup.py`. No `requirements.txt` as the source of truth — the lockfile is.

## One `pyproject.toml`

PEP 621 `[project]` metadata plus every tool's config lives in a single `pyproject.toml`. One file to read, one file to
review.

```toml
[project]
name = "my-project"
version = "0.1.0"
description = "..."
requires-python = ">=3.14"
dependencies = ["httpx>=0.27"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[dependency-groups]              # PEP 735 — NOT runtime dependencies
dev = ["ruff", "mypy", "ty"]     # pin lower bounds to the current stable releases — verify, don't copy a number
test = ["pytest", "pytest-cov"]
```

Keep dev and test tools in **dependency groups**, not in `[project.dependencies]`. Runtime metadata is what your users
install; a linter and a test runner have no business leaking into it. uv installs groups for local work; they never ship
in the wheel.

## uv as the default project manager

Use **uv** (Astral, Rust) for everything: creating the project, resolving and locking dependencies, running commands in
the managed environment. It replaces pip + virtualenv + pip-tools and is fast enough that re-syncing is instant.

```bash
uv init --package my-project   # scaffold src/ layout + pyproject.toml
uv add httpx                   # add a runtime dependency, update lock + env
uv add --group dev ruff mypy   # add to a dependency group
uv lock                        # resolve and write uv.lock
uv sync                        # make the env match the lock exactly
uv run pytest                  # run inside the managed env, no manual activation
```

**Commit `uv.lock`.** It pins the exact resolved versions and hashes so every machine, CI runner, and teammate gets a
byte-identical environment. The lockfile — not a hand-maintained `requirements.txt` — is the reproducibility contract.

## Ruff: one tool for lint and format

**Ruff** (Astral, Rust) replaces flake8, isort, Black, and pyupgrade with a single binary fast enough for editor-on-save
and pre-commit. Run `ruff check` (lint, with `--fix` for autofixes) and `ruff format` (the formatter).

```toml
[tool.ruff]
line-length = 88
target-version = "py314"

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM", "C4", "RUF", "PTH", "TC"]
```

What the recommended rule sets buy you:

| Code     | Rule set               | Why it earns its place                                    |
| -------- | ---------------------- | --------------------------------------------------------- |
| `E`, `F` | pycodestyle / Pyflakes | The baseline correctness + style errors                   |
| `I`      | isort                  | Import sorting, replaces a separate tool                  |
| `UP`     | pyupgrade              | Mechanically modernizes syntax (`list[int]`, `X \| None`) |
| `B`      | flake8-bugbear         | Real bug patterns — mutable defaults, etc.                |
| `SIM`    | flake8-simplify        | Collapses needlessly verbose constructs                   |
| `C4`     | flake8-comprehensions  | Pushes toward proper comprehensions                       |
| `RUF`    | Ruff-native            | Ruff's own high-signal lints                              |
| `PTH`    | flake8-use-pathlib     | Flags `os.path` usage in favor of `pathlib`               |
| `TC`     | flake8-type-checking   | Moves type-only imports into `TYPE_CHECKING` blocks       |

Line length 88 (the Black default). Let `ruff format` own formatting; never hand-format and never run a second
formatter alongside it.

## Type checker: a dependable strict gate, plus a fast newcomer

Run a strict type checker in CI and treat its output as build-breaking. As of mid-2026 the dependable CI gate is
**pyright or mypy in strict mode** — both are mature, both have years of ecosystem coverage.

```toml
[tool.mypy]
strict = true
warn_unused_ignores = true
warn_redundant_casts = true

[tool.pyright]
typeCheckingMode = "strict"
reportMissingTypeStubs = "warning"
```

The fast Rust newcomers — **ty** (Astral) and **pyrefly** (a comparable fast checker) — are excellent for editor and
local feedback because they are near-instant. But **ty is in BETA as of mid-2026**: run it _alongside_ mypy/pyright in
CI for speed and early signal, not as the sole gate. The mature checker stays authoritative until the newcomer reaches
stable parity.

```bash
uv run ty check        # fast local/editor pass
uv run mypy src        # authoritative CI gate (or pyright)
```

Start strict and disable individual rules with a documented, file-scoped reason — never start permissive and add rules
later. Library authors: ship `py.typed` and verify the public surface with `mypy.stubtest` / `pyright --verifytypes`.

## pytest patterns

Use pytest with fixtures, parametrization, and the built-in `tmp_path`. Test error paths with `pytest.raises`, not by
asserting on return values.

```python
import pytest
from my_project.core import parse_port

@pytest.mark.parametrize(
    ("raw", "expected"),
    [("8080", 8080), ("1", 1), ("65535", 65535)],
)
def test_parse_port_valid(raw: str, expected: int) -> None:
    assert parse_port(raw) == expected

def test_parse_port_out_of_range() -> None:
    with pytest.raises(ValueError, match="out of range"):
        parse_port("70000")

def test_writes_config(tmp_path) -> None:
    target = tmp_path / "app.toml"          # tmp_path is per-test, auto-cleaned
    write_config(target, {"debug": True})
    assert "debug" in target.read_text()
```

Promote warnings to errors so a `DeprecationWarning` fails the build instead of scrolling past:

```toml
[tool.pytest.ini_options]
addopts = "-W error --strict-markers"
testpaths = ["tests"]
```

Keep performance benchmarks in a **separate CI job** from correctness tests — benchmarks belong on a stable, pinned
runner with preserved result artifacts, and microbenchmark noise should never fail the unit-test job. (See
`performance.md` for the measurement discipline.)

## A baseline CI matrix

1. **Lint/format** — `ruff check` and `ruff format --check`.
2. **Types** — mypy/pyright strict (authoritative); ty/pyrefly alongside for speed. `stubtest`/`verifytypes` for
   libraries.
3. **Correctness** — `pytest -W error`, with coverage.
4. **Packaging** (libraries) — build sdist + wheel, smoke-import from the built wheel; `cibuildwheel` for native
   extensions.
5. **Performance** (if relevant) — separate, pinned, artifact-preserving benchmark job.

## Pre-commit self-check

- [ ] `uv.lock` is committed and `uv sync` reproduces the environment.
- [ ] `ruff check` and `ruff format --check` are clean.
- [ ] The strict type checker (mypy/pyright) passes with zero errors; ty/pyrefly run alongside, not as the sole gate.
- [ ] Dev/test tools are in dependency groups, not runtime `[project.dependencies]`.
- [ ] Tests cover happy and error paths (`pytest.raises`); warnings are promoted to errors.
