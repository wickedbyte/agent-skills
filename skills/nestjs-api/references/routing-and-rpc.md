# Routing — REST and Resource-Action RPC

NestJS controllers map paths to methods. REST is straightforward; the interesting part of this contract style is the
**resource-action RPC** route — `POST /tasks/{taskId}:complete` — which puts a literal colon in the path segment. This
file covers both, and the one routing trap that every implementation must handle.

## REST controllers

A REST controller marshals HTTP into a single service call and serializes the result. It contains no business logic.

```ts
@Controller("tasks")
export class TasksController {
    constructor(private readonly tasks: TasksService) {}

    @Post()
    @HttpCode(201)
    async create(@Body(new ZodValidationPipe(createTaskSchema)) body: CreateTaskInput) {
        return taskEnvelope(await this.tasks.createTask(body));
    }

    @Get()
    async list(@Query(new ZodValidationPipe(listTasksQuerySchema)) query: ListTasksQuery) {
        return taskListEnvelope(await this.tasks.listTasks(query));
    }

    @Get(":taskId")
    async get(@Param("taskId") taskId: string) {
        return taskEnvelope(await this.tasks.getTask(taskId));
    }

    @Patch(":taskId")
    async patch(
        @Param("taskId") taskId: string,
        @Body(new ZodValidationPipe(patchTaskSchema)) body: PatchTaskInput,
    ) {
        return taskEnvelope(await this.tasks.patchTask(taskId, body));
    }
}
```

Conventions:

- **`@HttpCode`** where the status isn't the Nest default (POST defaults to 201, everything else to 200). A command that
  returns 200 on `POST` needs `@HttpCode(200)`.
- **Validate every input** through a pipe — `@Body`, `@Query`, and even `@Param` when the id has a shape worth checking.
  The argument type (`CreateTaskInput`) is `z.infer` of the schema, so it's honest only because the pipe ran.
- **Return envelopes, not bare entities.** The contract wraps responses (`{ "task": … }`); the serializer builds them so
  the controller stays a one-liner.
- **Don't catch errors here.** Throw from the service/domain; the global filter renders them (see `references/errors.md`).

## The resource-action RPC trap

The contract uses a literal colon: `POST /tasks/{taskId}:complete`, `…:delegate`, `…:assignProjects`, etc. You **cannot**
declare these as literal routes, because Fastify's router (`find-my-way`) and Express both treat `:` as the start of a
path parameter. `@Post("tasks/:taskId:complete")` is ambiguous and will not match the way you want; escaping the colon
is router-version-dependent and fragile.

**The robust pattern: one catch route + split-on-last-colon dispatch.** Declare a single `@Post(":taskId")` that
receives the entire `task_01J…:complete` segment as one string, then split it yourself and dispatch.

### The splitter (pure, unit-tested)

```ts
export interface ColonCommand {
    readonly id: string;
    readonly command: string | null;
}

export function splitColonCommand(raw: string): ColonCommand {
    const idx = raw.lastIndexOf(":");
    if (idx <= 0 || idx === raw.length - 1) {
        return { id: raw, command: null };
    }
    return { id: raw.slice(0, idx), command: raw.slice(idx + 1) };
}
```

Split on the **last** colon, not the first: an opaque id could itself contain a colon, and the command is always the
final segment. The guards (`idx <= 0`, `idx === length - 1`) treat a leading colon, a trailing colon, and a
colon-free string all as "no command" → a bare resource id.

### The command allow-list (typed)

```ts
export const TASK_COMMANDS = [
    "complete", "cancel", "backlog", "makeActionable", "delegate", "reschedule", "assignProjects",
] as const;

export type TaskCommandName = (typeof TASK_COMMANDS)[number];

const TASK_COMMAND_SET = new Set<string>(TASK_COMMANDS);

export function isTaskCommand(command: string): command is TaskCommandName {
    return TASK_COMMAND_SET.has(command);
}
```

`as const` + the derived union means the set of commands is a type, and `isTaskCommand` is a type guard — downstream
`switch`es over `TaskCommandName` can be made exhaustive with a `never` default.

### The dispatcher controller

```ts
@Controller("tasks")
export class TaskCommandsController {
    constructor(private readonly tasks: TasksService) {}

    @Post(":taskId")
    @HttpCode(200)
    async dispatch(@Param("taskId") raw: string, @Body() body: unknown) {
        const { id, command } = splitColonCommand(raw);
        if (command === null || !isTaskCommand(command)) {
            throw new NotFoundError(`no such task command on ${raw}`);
        }
        return taskEnvelope(await this.tasks.runCommand(id, command, body));
    }
}
```

How it resolves against the REST controller:

- `GET /tasks/:taskId` and `PATCH /tasks/:taskId` live on `TasksController`; the RPC `@Post(":taskId")` lives on
  `TaskCommandsController`. They share the `tasks` prefix but different verbs, so there is no collision — `GET`/`PATCH`
  never reach the dispatcher.
- A `POST /tasks` (create) is `@Post()` with no param, distinct from `@Post(":taskId")`.
- `@Body() body: unknown` — the command body is validated **inside** `runCommand` against the per-command schema (each
  command has a different body), so the dispatcher keeps it `unknown` and doesn't presume a shape.

### Validating and routing inside the service

`runCommand` validates the body against the matching schema, builds the domain command, and runs it. This is where the
per-command Zod schema is applied and where unknown-but-shaped errors become typed domain commands:

```ts
async runCommand(taskId: string, command: TaskCommandName, body: unknown): Promise<TaskAggregate> {
    switch (command) {
        case "complete": {
            const input = completeSchema.parse(body);
            return this.execute(taskId, (state) => ({ kind: "complete", completedAt: input.completedAt ?? null }));
        }
        case "delegate": {
            const input = delegateSchema.parse(body);
            return this.execute(taskId, () => ({ kind: "delegate", ...input }));
        }
        // …one case per command; exhaustive with a never default…
    }
}
```

(`execute` is the load → decide → commit helper from `references/persistence.md`.)

## The mandatory routing test

Every implementation must prove the colon is parsed correctly. Test the splitter directly **and** the HTTP behavior:

```ts
describe("splitColonCommand", () => {
    it("splits on the last colon", () => {
        expect(splitColonCommand("task_01J:complete")).toEqual({ id: "task_01J", command: "complete" });
    });
    it("treats a bare id as command-less", () => {
        expect(splitColonCommand("task_01J")).toEqual({ id: "task_01J", command: null });
    });
    it("keeps a colon inside the id, taking only the trailing command", () => {
        expect(splitColonCommand("a:b:complete")).toEqual({ id: "a:b", command: "complete" });
    });
});
```

```ts
it("a known command on a missing task → 404 not_found", async () => {
    const res = await request(server).post("/tasks/task_missing:complete").send({});
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe("not_found");
});

it("an unknown command → 404", async () => {
    const id = await createTask();
    const res = await request(server).post(`/tasks/${id}:frobnicate`).send({});
    expect(res.status).toBe(404);
});
```

## List / query endpoints

Query strings are strings — coerce and default them in the schema, then translate to a typed filter the read layer
understands. See `references/validation.md` for coercing query booleans (`?includeCompleted=true`) and
`references/persistence.md` for turning the filter into SQL.

```ts
export const listTasksQuerySchema = z.object({
    state: z.enum(["actionable", "delegated", "backlogged", "completed", "cancelled"]).optional(),
    projectId: z.string().optional(),
    includeCompleted: queryBool, // coerces "true"/"1" → boolean, default false
    includeCancelled: queryBool,
});
```

## Projects and meta

Projects follow the same shape: a REST controller plus a colon-command controller for `:archive` / `:restore`. Meta
endpoints (`/healthz`, `/readyz`, `/openapi.json`) are plain `@Get` handlers on small controllers and are exempt from
auth. There is no RPC dispatch for meta — they are fixed paths.
