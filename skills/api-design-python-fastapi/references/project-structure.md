# Project structure: the layered shape

This layout is the default for new work; adapt to an existing project's conventions rather than restructuring it.

This is the load-bearing reference: get the layering right and everything else slots in. All examples are fully typed and
assume `best-practices-python` style (modern syntax, frozen dataclasses, enums).

## The layered shape

Dependencies point **inward**. The domain core is pure and import-clean; persistence depends on the domain; only the
api layer depends on FastAPI.

```
src/<pkg>/
  main.py            # create_app() + lifespan + __main__ uvicorn entry
  config.py          # Settings (pydantic-settings)
  db.py              # async engine + session factory
  domain/            # NO fastapi / sqlalchemy / pydantic import
    errors.py        #   exception hierarchy (ValidationError, StateTransitionError, …)
    events.py        #   event/value-object dataclasses, enums
    <aggregate>.py   #   decide()/apply() pure functions
  store/             # NO fastapi import
    event_store.py   #   transactional append + queries
    projections.py   #   projection writers
    codec.py         #   snake_case <-> camelCase, date/datetime encoding
    errors.py        #   VersionConflictError, NotFoundError, …
  api/               # the only FastAPI-aware layer
    deps.py          #   Depends() providers + Annotated aliases
    schemas.py       #   Pydantic request/response models
    errors.py        #   exception handlers -> envelope
    <resource>.py    #   APIRouter per resource
    commands.py      #   RPC colon-routes
```

**Why a domain core with no framework imports.** It is unit-testable in microseconds, it cannot be coupled to a request
lifecycle by accident, and the rules live in exactly one place. The HTTP layer shrinks to translation, which is why it
needs so few tests of its own.
