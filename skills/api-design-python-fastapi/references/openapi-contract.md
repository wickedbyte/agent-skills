# Proving the OpenAPI contract

The contract layer proves the wire shape two independent ways: an equality test that the emitted spec matches the
canonical document, and Schemathesis property-based fuzzing that the running app honours it. The rest of the test
pyramid — unit, integration, functional — lives in `references/testing.md`.

## Contract layer 1: emitted OpenAPI ≡ canonical

The app must agree with the frozen spec. Decide the strategy up front:

- **Serve canonical verbatim** — load `openapi.yaml`, override `app.openapi` to return it, and serve it at
  `/openapi.json`. The contract is authoritative by construction; the test just guards that you didn't drift the routes
  away from it.
- **Emit from routes/models** — let FastAPI generate the schema; the test normalizes and compares it to the canonical
  doc, and you reconcile differences (notably the 422 schema — see `errors.md`).

```python
# tests/contract/test_openapi.py
from pathlib import Path

import yaml

from <pkg>.main import create_app

CANONICAL = yaml.safe_load(Path("../openapi.yaml").read_text())
_HTTP_METHODS = {"get", "post", "put", "patch", "delete"}


def test_emitted_openapi_equals_canonical() -> None:
    assert create_app().openapi() == CANONICAL


def test_every_documented_route_is_implemented() -> None:
    app = create_app()
    documented = {
        (method.upper(), path)
        for path, item in CANONICAL["paths"].items()
        for method in item
        if method in _HTTP_METHODS
    }
    implemented = {
        (method, getattr(route, "path", ""))
        for route in app.routes
        for method in getattr(route, "methods", set()) or set()
    }
    missing = documented - implemented
    assert not missing, f"documented but not implemented: {sorted(missing)}"
```

The route-coverage test catches the asymmetric failure the equality test can miss when you serve canonical verbatim: a
documented path with no handler. Add the reverse check (implemented but undocumented) if your contract must be exhaustive.

## Contract layer 2: Schemathesis property-based fuzzing

The equality test proves the _documented_ shape; Schemathesis proves the _running_ app honours it — it generates
edge-case requests from the schema and asserts every response conforms (status in the documented set, body matches the
declared schema, no 500s, no undeclared fields). Run it as pytest tests or as a CLI step in CI against the live
container.

```python
# tests/contract/test_fuzz.py
import schemathesis

schema = schemathesis.openapi.from_path("../openapi.yaml", base_url="http://localhost:8080")


@schema.parametrize()
def test_api_conforms_to_spec(case: schemathesis.Case) -> None:
    case.call_and_validate()       # generate -> send -> assert response matches the schema
```

Or from the CLI (verify the current invocation — the CLI surface evolves between major versions):

```bash
uv run st run ../openapi.yaml --url http://localhost:8080
```

Schemathesis is property-based: each failure is minimized and replayed as a reproducible request, so a red run hands you
the exact payload that broke the contract. Treat any failure as a contract bug in the implementation, not the spec —
the spec is frozen.
