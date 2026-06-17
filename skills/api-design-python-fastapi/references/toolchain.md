# Toolchain skeleton & the mechanical gate

**Detect and respect the project's runner.** What follows is the greenfield default. **In a `uv` project**, every
command is `uv run …` (`uv run ruff`, `uv run pytest`); in a Poetry, pip-tools, pipenv, or conda project, use that
project's runner instead. `uv` is the greenfield default, not a migration mandate — never system `pip`/`python3` in a
`uv` project, but never force an existing project off the manager it already uses. If the project drives its tools
through `docker compose` or a `Makefile`/task runner, invoke them that way.

The toolchain is the `pyproject.toml`/`Makefile` skeleton plus the one mechanical gate every change must pass. All
examples assume `best-practices-python` style and the uv + Ruff + type-checker stack.

## Toolchain skeleton

- **`pyproject.toml`** — PEP 621 metadata, runtime deps under `[project].dependencies`, dev tools under
  `[dependency-groups].dev` (so they don't leak into the wheel), and all tool config (`[tool.ruff]`, `[tool.mypy]`,
  `[tool.pytest.ini_options]`) in the one file. Commit `uv.lock`.
- **`Makefile`** — the mechanical gate as targets: `fmt-check` (`ruff format --check`), `lint` (`ruff check`), `types`
  (`mypy --strict src`), `test` (`pytest`), and a `gate` that runs all four in order. Add `up`/`down`/`logs` for the
  compose stack and `migrate-up`/`migrate-down` for Alembic.

Keep `pytest.ini_options` configured for async: `asyncio_mode = "auto"`, `pythonpath = ["src"]`, and any custom markers
(`conformance`, `sse`) you select tests by.

## The mechanical gate

The whole suite sits behind one gate, every step green before advancing:

```
ruff format --check .     # formatting
ruff check .              # lint
mypy --strict src         # types — the real correctness signal
pytest                    # unit -> integration -> functional -> contract
```

Wire it as `make gate` and run it in CI. A step is done only when the gate exits zero across the board (plus, where it
applies, the emitted-OpenAPI ≡ canonical contract test and a clean Schemathesis run).
