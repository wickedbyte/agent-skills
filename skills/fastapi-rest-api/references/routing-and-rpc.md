# Routing: REST endpoints and the resource-action RPC pattern

FastAPI routing is declarative: an `APIRouter` per resource, type-annotated parameters that FastAPI parses and
validates, and a Pydantic body model. This reference covers REST routing, parameter parsing, response shaping, and — in
depth — the resource-action **colon-route** pattern that the contract uses for RPC commands.

## One router per resource, composed in the factory

```python
# api/tasks.py
from typing import Any

from fastapi import APIRouter, Query, status

from .deps import Clock, Store
from .schemas import CreateTaskRequest, PatchTaskRequest
from ..domain.errors import ValidationError
from ..store.errors import NotFoundError

router = APIRouter(tags=["tasks"])


@router.post("/tasks", status_code=status.HTTP_201_CREATED)
async def create_task(body: CreateTaskRequest, store: Store, clock: Clock) -> dict[str, Any]:
    state, _ = await store.create_task(body.to_command(), now=clock())
    return {"task": task_to_dict(state)}


@router.get("/tasks")
async def list_tasks(
    store: Store,
    state: str | None = Query(default=None),
    project_id: str | None = Query(default=None, alias="projectId"),
    include_completed: bool = Query(default=False, alias="includeCompleted"),
) -> dict[str, Any]:
    tasks = await store.list_tasks(state=state, project_id=project_id, include_completed=include_completed)
    return {"tasks": [task_to_dict(t) for t in tasks]}


@router.get("/tasks/{task_id}")
async def get_task(task_id: str, store: Store) -> dict[str, Any]:
    task = await store.get_task(task_id)
    if task is None:
        raise NotFoundError("task")
    return {"task": task_to_dict(task)}


@router.patch("/tasks/{task_id}")
async def patch_task(task_id: str, body: PatchTaskRequest, store: Store, clock: Clock) -> dict[str, Any]:
    task = await store.get_task(task_id)
    if task is None:
        raise NotFoundError("task")
    state, _ = await store.update_task(task, body.to_command(), now=clock())
    return {"task": task_to_dict(state)}
```

The router is then mounted once in `create_app`: `app.include_router(tasks.router, dependencies=[Depends(require_auth)])`.

### Parameter parsing — let FastAPI do it, then constrain

FastAPI infers the parameter source from the signature: a name that appears in the path is a **path** param, a Pydantic
model is the **body**, everything else is a **query** param. Make the contract explicit with `Path`/`Query`/`Header` and
their constraints rather than validating by hand:

```python
from typing import Annotated
from fastapi import Path, Query

Limit = Annotated[int, Query(ge=1, le=200)]
TaskId = Annotated[str, Path(min_length=1)]

@router.get("/tasks/{task_id}/history")
async def history(task_id: TaskId, store: Store, limit: Limit = 50) -> dict[str, Any]:
    ...
```

- Use `alias="projectId"` to accept a camelCase query/header while the Python name stays snake_case.
- Constraints (`ge`, `le`, `min_length`, `pattern`) become OpenAPI schema **and** runtime validation — a rejected value
  produces a 422 you'll reshape into your envelope (see `validation-and-errors.md`).
- Prefer `Annotated[T, Query(...)]` aliases over inline defaults; they're reusable and keep signatures readable.

## The resource-action RPC pattern (`POST /tasks/{id}:complete`)

The contract expresses commands as a literal colon action on a resource: `POST /tasks/{taskId}:complete`,
`:delegate`, `:assignProjects`, and so on. This is the one routing detail that bites every implementation, because of
how Starlette path matching works.

### The trap

Starlette path parameters stop at `/` but **include** `:`. So a naive generic route

```python
@router.post("/tasks/{task_id}")        # WRONG for commands
```

would match `POST /tasks/01J9Z…:complete` and capture `task_id = "01J9Z…:complete"` — the command suffix leaks into the
id. You must not let that happen.

### The fix: explicit colon routes + a colon-excluding pattern

Define one **explicit** route per command with the literal `:command` in the path, and constrain the id param so it
cannot contain a colon (or slash):

```python
# api/commands.py
from collections.abc import Callable
from datetime import datetime
from typing import Annotated, Any

from fastapi import APIRouter, Path

from .deps import Clock, Store
from .schemas import AssignProjectsRequest, CompleteTaskRequest, DelegateTaskRequest
from ..domain.task import TaskCommand, decide
from ..store.event_store import EventStore
from ..store.errors import NotFoundError

router = APIRouter(tags=["task-commands"])

# `^[^:/]+$` — one or more chars that are neither ':' nor '/'. The literal ':complete'
# in the path matches the action; the pattern keeps `task_id` free of the suffix.
CmdTaskId = Annotated[str, Path(pattern=r"^[^:/]+$")]


async def _run(
    store: EventStore, clock: Callable[[], datetime], task_id: str, cmd: TaskCommand
) -> dict[str, Any]:
    """Shared command pipeline: load -> 404 -> decide -> commit -> serialize."""
    task = await store.get_task(task_id)
    if task is None:
        raise NotFoundError("task")
    now = clock()
    events = decide(task, cmd, now)              # pure domain guard
    state, _ = await store.commit_task(task.id, task, events, now)
    return {"task": task_to_dict(state)}


@router.post("/tasks/{task_id}:complete")
async def complete_task(
    task_id: CmdTaskId, store: Store, clock: Clock, body: CompleteTaskRequest | None = None
) -> dict[str, Any]:
    cmd = (body or CompleteTaskRequest()).to_command()
    return await _run(store, clock, task_id, cmd)


@router.post("/tasks/{task_id}:delegate")
async def delegate_task(
    task_id: CmdTaskId, store: Store, clock: Clock, body: DelegateTaskRequest
) -> dict[str, Any]:
    return await _run(store, clock, task_id, body.to_command())


@router.post("/tasks/{task_id}:assignProjects")
async def assign_projects(
    task_id: CmdTaskId, store: Store, clock: Clock, body: AssignProjectsRequest
) -> dict[str, Any]:
    return await _run(store, clock, task_id, body.to_command())
```

### Why this works and what to verify

- The router matches the literal `:complete` / `:delegate` suffix as part of the path, so each command has a distinct
  route and a distinct OpenAPI `operationId`.
- `Path(pattern=r"^[^:/]+$")` makes `task_id` reject anything containing a colon, so the suffix can never bleed into the
  id even if a future route changed.
- **Registration order:** include the command routes **before** the generic `/tasks/{task_id}` if any generic catch-all
  exists, so the specific colon routes win. With the explicit literal suffix this is rarely ambiguous, but keep the
  order deterministic.
- **Test it explicitly.** A routing test must assert both halves: the colon route parses the id without the suffix, and
  the plain `GET /tasks/{id}` still works for an id with no colon.

```python
async def test_colon_command_parses_id_without_suffix(client: AsyncClient) -> None:
    tid = await create_task(client)
    resp = await client.post(f"/tasks/{tid}:complete")
    assert resp.status_code == 200
    assert resp.json()["task"]["id"] == tid          # the suffix did NOT leak in
    assert resp.json()["task"]["state"] == "completed"
```

### Generalizing it

For many commands, a small registration helper keeps `commands.py` flat and consistent. Each command is `(suffix,
request-model)`; the handler body is always load → decide → commit:

```python
from collections.abc import Awaitable, Callable

def register_command[ReqT: CommandRequest](
    router: APIRouter,
    *,
    suffix: str,
    request_model: type[ReqT],
) -> None:
    @router.post(f"/tasks/{{task_id}}:{suffix}", name=f"task_{suffix}")
    async def handler(task_id: CmdTaskId, store: Store, clock: Clock, body: ReqT) -> dict[str, Any]:
        return await _run(store, clock, task_id, body.to_command())
```

Prefer the explicit routes when the commands differ enough (optional vs required bodies) that a single signature would
obscure them — clarity over cleverness.

## Mapping the request to a domain command at the edge

Handlers must not pass Pydantic models into the domain. Each request model exposes `to_command()` that produces the
frozen domain command, doing any strict parsing the framework's lenient coercion wouldn't (see
`validation-and-errors.md`). The handler's job is exactly three lines: parse (FastAPI), dispatch (`decide`/store), and
serialize.

## Response shaping

Two viable styles; pick one and be consistent:

- **Serialize a domain object to a `dict` at the edge** (as above) — explicit, no second model to keep in sync, and
  trivial to match camelCase wire names. Good when you serve a canonical OpenAPI file and don't need FastAPI to generate
  response schemas.
- **Declare a `response_model`** Pydantic model on the route — FastAPI validates and filters the response and documents
  it in the generated OpenAPI. Good when you let FastAPI emit the schema. Set `response_model_exclude_none` only if the
  contract actually omits nulls; many contracts require explicit `null`, so check before enabling it.

Set explicit `status_code=status.HTTP_201_CREATED` on creates and `204` on no-content deletes; don't rely on the
default 200 where the contract says otherwise.
</content>
