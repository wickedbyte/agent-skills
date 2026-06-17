# The Domain Core — Pure, Test-First, Nest-Free

This is where the rules of the API live, and it is the part NestJS must never touch. The core is plain TypeScript:
`readonly` data, discriminated unions, and pure functions. No `@Injectable()`, no request object, no database, no clock
read from inside. Because it is pure, it tests in microseconds and every invariant gets a unit test before any HTTP code
exists. The example below is event-sourced (the most demanding shape); a CRUD domain uses the same `decide`-returns-
changes structure without the event log.

## Aggregates are `readonly` interfaces

The aggregate is the current folded state plus its `version` (event count; `0` = does not exist):

```ts
export interface TaskAggregate {
    readonly id: string;
    readonly title: string;
    readonly notes: string | null;
    readonly state: TaskState;
    readonly projectIds: readonly string[];
    readonly startDate: IsoDate | null; // "YYYY-MM-DD"
    readonly dueDate: IsoDate | null;
    readonly delegatedTo: string | null;
    readonly waitingFor: string | null;
    readonly delegatedAt: Iso8601 | null; // RFC3339 UTC
    readonly completedAt: Iso8601 | null;
    readonly cancelledAt: Iso8601 | null;
    readonly createdAt: Iso8601;
    readonly updatedAt: Iso8601;
    readonly version: number;
}

export type TaskState =
    | "actionable"
    | "delegated"
    | "backlogged"
    | "completed"
    | "cancelled";
```

`IsoDate` and `Iso8601` are **branded** strings so a date-only value can't be assigned where a timestamp is expected:

```ts
export type IsoDate = string & { readonly __brand: "IsoDate" };
export type Iso8601 = string & { readonly __brand: "Iso8601" };
```

## Commands and events are discriminated unions

A **command** is an intent from the boundary; an **event** is a fact the command produced. Both are unions discriminated
by a literal (`kind` for commands, `type` for events):

```ts
export type TaskCommand =
    | {
          readonly kind: "capture";
          readonly title: string;
          readonly notes: string | null;
          readonly state: TaskState | null;
          readonly startDate: IsoDate | null;
          readonly dueDate: IsoDate | null;
          readonly projectIds: readonly string[];
      }
    | {
          readonly kind: "edit";
          readonly title: string | null;
          readonly notes: Patch<string | null>;
      }
    | { readonly kind: "complete"; readonly completedAt: Iso8601 | null }
    | {
          readonly kind: "delegate";
          readonly delegatedTo: string;
          readonly waitingFor: string | null;
          readonly dueDate: IsoDate | null;
      }
    | {
          readonly kind: "reschedule";
          readonly startDate: Patch<IsoDate | null>;
          readonly dueDate: Patch<IsoDate | null>;
      }
    | {
          readonly kind: "assignProjects";
          readonly projectIds: readonly string[];
      };
// …backlog, cancel, makeActionable…

export type TaskEventData =
    | {
          readonly type: "TaskCaptured";
          readonly title: string;
          readonly notes: string | null;
          readonly state: TaskState;
          readonly startDate: IsoDate | null;
          readonly dueDate: IsoDate | null;
      }
    | { readonly type: "TaskCompleted"; readonly completedAt: Iso8601 }
    | {
          readonly type: "TaskDelegated";
          readonly delegatedTo: string;
          readonly waitingFor: string | null;
          readonly dueDate: IsoDate | null;
          readonly delegatedAt: Iso8601;
      }
    | {
          readonly type: "TaskProjectsAssigned";
          readonly projectIds: readonly string[];
      };
// …one variant per event in the catalog…
```

The event envelope wraps the data with stream metadata (this is what the store persists):

```ts
export interface DomainEvent<T> {
    readonly id: string; // "event_…" ULID, globally ordered
    readonly streamType: "Task" | "Project";
    readonly streamId: string;
    readonly version: number; // 1-based, gap-free per stream
    readonly data: T;
    readonly occurredAt: Iso8601;
}
```

## `decide` — guards in, events out, no side effects

`decide(state, command, now)` is the heart of the domain: it validates the guards and returns the resulting events.
Note `now: Date` is a **parameter** — the core never reads the clock, so it is deterministic and testable.

```ts
export function decideTask(
    state: TaskAggregate,
    command: TaskCommand,
    now: Date,
): readonly TaskEventData[] {
    switch (command.kind) {
        case "capture":
            return decideCapture(command); // checks title (I1), date range (I3)
        case "edit":
            return decideEdit(command); // allowed even in a terminal state
        case "complete":
            ensureNotTerminal(state, "complete");
            return [
                {
                    type: "TaskCompleted",
                    completedAt: command.completedAt ?? isoNow(now),
                },
            ];
        case "delegate": {
            ensureNotTerminal(state, "delegate");
            if (command.delegatedTo === "") {
                throw new ValidationError(
                    "delegatedTo is required",
                    "delegatedTo",
                );
            }
            const dueDate = command.dueDate;
            checkDateRange(state.startDate, dueDate);
            return [
                {
                    type: "TaskDelegated",
                    delegatedTo: command.delegatedTo,
                    waitingFor: command.waitingFor,
                    dueDate,
                    delegatedAt: isoNow(now),
                },
            ];
        }
        case "reschedule": {
            ensureNotTerminal(state, "reschedule");
            const startDate = resolvePatch(state.startDate, command.startDate);
            const dueDate = resolvePatch(state.dueDate, command.dueDate);
            checkDateRange(startDate, dueDate);
            return [{ type: "TaskRescheduled", startDate, dueDate }];
        }
        // …backlog, cancel, makeActionable, assignProjects…
        default: {
            const unreachable: never = command;
            return unreachable;
        }
    }
}
```

Three things make this correct:

1. **Exhaustiveness via `never`.** The `default` branch assigns `command` to `never`. Add a new command variant and
   forget a `case` → compile error. This is TypeScript's totality tool; use it on every union `switch`.
2. **Guards throw named domain errors.** `ensureNotTerminal` throws `StateTransitionError` (→ 409); a bad input throws
   `ValidationError(message, field)` (→ 422 with `details.field`). The domain decides _what_ is wrong; the filter
   decides the _status_ (see `references/errors.md`).
3. **Partial updates resolve at decide-time.** `resolvePatch(current, patch)` merges absent/null/value against current
   state and `decide` emits the **resolved** dates in the event — so `apply` never needs prior state and the date-range
   guard checks the resolved pair, not the raw partial.

```ts
function resolvePatch<T>(current: T, patch: Patch<T>): T {
    return patch.set ? patch.value : current;
}
```

## `apply` — fold one event onto state, purely

`apply(state, event)` returns the next state. It is total over the event union and sets `updatedAt` to every event's
time:

```ts
export function applyTask(
    state: TaskAggregate,
    event: DomainEvent<TaskEventData>,
): TaskAggregate {
    const base: TaskAggregate = {
        ...state,
        id: event.streamId,
        version: event.version,
        updatedAt: event.occurredAt,
    };
    const data = event.data;
    switch (data.type) {
        case "TaskCaptured":
            return {
                ...base,
                createdAt: event.occurredAt,
                title: data.title,
                notes: data.notes,
                state: data.state,
                startDate: data.startDate,
                dueDate: data.dueDate,
            };
        case "TaskCompleted":
            return {
                ...base,
                state: "completed",
                completedAt: data.completedAt,
            };
        case "TaskDelegated":
            return {
                ...base,
                state: "delegated",
                delegatedTo: data.delegatedTo,
                waitingFor: data.waitingFor,
                dueDate: data.dueDate,
                delegatedAt: data.delegatedAt,
            };
        case "TaskProjectsAssigned":
            return { ...base, projectIds: data.projectIds }; // replace wholesale
        // …every other event…
        default: {
            const unreachable: never = data;
            return unreachable;
        }
    }
}

export function foldTask(
    events: readonly DomainEvent<TaskEventData>[],
): TaskAggregate {
    return events.reduce(applyTask, emptyTask());
}
```

`foldTask` is the projection's truth: a stream replayed from version 1 reproduces the aggregate exactly. That property
is what lets the store rebuild projections from the event log (see `references/persistence.md`).

## View predicates are pure too

Saved views (today / upcoming / overdue / …) are predicates over the aggregate. Keeping them in `domain/views.ts` means
they can be unit-tested directly **and** translated to SQL `WHERE` clauses that must agree with them:

```ts
export function isOverdue(t: TaskAggregate, today: IsoDate): boolean {
    return (
        (t.state === "actionable" || t.state === "delegated") &&
        t.dueDate !== null &&
        t.dueDate < today &&
        t.completedAt === null &&
        t.cancelledAt === null
    );
}
```

`today` is passed in (server UTC date), never read from `Date` inside the predicate — same purity rule as the clock.

## Test-first, table-driven, one assertion per invariant

Write the failing test from the invariant, then implement. Pure functions make this fast and exhaustive:

```ts
describe("decideTask — capture", () => {
    it("empty title → ValidationError on field 'title'", () => {
        expect(() =>
            decideTask(emptyTask(), capture({ title: "" }), NOW),
        ).toThrowError(expect.objectContaining({ field: "title" }));
    });

    it("no state defaults to actionable", () => {
        const [event] = decideTask(emptyTask(), capture(), NOW);
        expect(event).toMatchObject({
            type: "TaskCaptured",
            state: "actionable",
        });
    });

    it.each<TaskState>(["actionable", "backlogged"])(
        "capture allows state %s",
        (state) => {
            const [event] = decideTask(emptyTask(), capture({ state }), NOW);
            expect(event).toMatchObject({ state });
        },
    );

    it("startDate after dueDate → ValidationError on 'dueDate'", () => {
        expect(() =>
            decideTask(
                emptyTask(),
                capture({
                    startDate: d("2026-02-01"),
                    dueDate: d("2026-01-01"),
                }),
                NOW,
            ),
        ).toThrowError(expect.objectContaining({ field: "dueDate" }));
    });
});
```

Keep a checklist mapping each invariant to its test name; the domain layer should be **fully green before any
controller exists** (see `references/testing.md`).
