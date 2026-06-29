# Jobcenter

Jobcenter is a restartable, asynchronous, distributed workflow engine: business processes written as ordinary code, made durable by replay. This document describes the features of the Jobcenter service and how applications integrate with it.

> **Motivation.** Jobcenter grows out of [`postjob`](https://github.com/mediafellows/postjob), a Ruby + PostgreSQL workflow engine, and keeps its core idea — replay-based orchestration. It differs in two deliberate ways: all orchestration logic lives in the application (starting with Go) rather than in the database, and the database is reduced to two special capabilities plus plain storage. The remainder of this document describes Jobcenter on its own terms. The companion design docs in [`../`](../README.md) cover the architecture, data model, store interface, engine, and roadmap.

## What is Jobcenter

On a basic level Jobcenter acts as a job queue, but it is much more, offering the features of a workflow engine with deep integration into a host language. **Jobcenter is not limited to Go: Go is simply the first host language.** The engine, the replay model, the protobuf payload format, and the HTTP runner interface are all language-agnostic; a runner in any language only needs to speak the runner interface and exchange proto payloads, so additional host-language SDKs (e.g. Elixir, Ruby) can be added later. Go is the first such SDK, and the rest of this document uses it for examples.

### Jobcenter as a job queue

At its simplest, a runner connects to Jobcenter, checks out a job that is ready to run, performs it, and reports success or failure. Like other queues it supports: jobs described by a name and arguments; an optional `run_at` timestamp; organization into queues for resource balancing; one or more runners consuming jobs; and automatic retries with exponential backoff.

### Jobcenter as a workflow engine

A workflow in Jobcenter is a program, and it supports the control-flow primitives that are typical for synchronous programs — loops, conditionals, error handling — to orchestrate multiple steps that may individually fail or that coordinate external systems. Unlike a classic workflow engine built from *decider* and *activity* nodes (as in AWS SWF), or one that distinguishes between *workflows* (which handle the logic) and *activities* (which do the real work), Jobcenter expresses control flow directly in the host language. The engine makes that code durable and restartable through replay.

## A working workflow

Terminology:

- **workflow implementation** — code that describes the steps of a business process.
- **workflow instance** — a running instance, created by *enqueuing* the workflow.
- **job** — an individual step in a workflow.
- **a resolved job** — a job that reached its final result: success (`ok`), failure (`failed`), or `timeout`.

The canonical example is Fibonacci. In Jobcenter it is a typed workflow: its request is a protobuf message and its result is a plain `int64`, so awaited children compose directly with `a + b` (see [Golang SDK](#golang-sdk) for how value results work):

```go
var Fibonacci = jobcenter.NewWorkflow("Fibonacci", "1.0",
    func(ctx *jobcenter.WfContext, req *pb.FibReq) (int64, error) {
        if req.N <= 2 {
            return 1, nil
        }
        f1 := jobcenter.Async(ctx, Fibonacci, &pb.FibReq{N: req.N - 2})
        f2 := jobcenter.Async(ctx, Fibonacci, &pb.FibReq{N: req.N - 1})
        a := f1.Await(ctx)
        b := f2.Await(ctx)
        return a + b, nil
    })
```

To run it:

```
# register/enqueue and run, all from the CLI
jobcenter enqueue Fibonacci '{"n":3}'
jobcenter run:all
```

### So, what is happening here?

A runner pulls a ready job from the `default` queue, finds it must call `Fibonacci`, and invokes the function with the decoded request. Since `n = 3 > 2`, it spawns two child workflows and awaits their sum.

### But how does that really work?

The full story is replay:

1. A `Fibonacci` job with `n = 3` is enqueued and becomes `ready`.
2. A runner claims it and runs the function from the top until the first `Await`.
3. It looks for a matching **child job** — same parent, same workflow, same arguments.
4. None exists, so it creates one, sets the parent to `sleep`, and stops executing it.
5. The runner picks up the newly enqueued child and runs it; on success it writes the result and sets the child to `ok`.
6. Completing the child **wakes the parent** (sets it back to `ready`).
7. The runner picks the parent up again and **re-runs the function from the top**. This time the first `Await` finds its completed child and returns the cached result; the second `Await` has no child yet, so it enqueues one and sleeps again.
8. When the second child completes, the parent runs once more, both `Await`s return cached results, and the function returns the final value.

This combination of engine logic (enabling/disabling jobs based on whether unfinished children remain) and workflow code effectively turns each `Await`ed call into a **memoized** method call within the current job — guaranteeing each side effect runs exactly once.

### Be aware, though, that…

The replay model comes with some footguns:

- Because an unresolved `Await` unwinds the current execution (Jobcenter uses an internal `panic`/`recover` signal, not a returned error), any `defer` blocks in a workflow body will run on every suspension. Do not rely on `defer` for cleanup that must happen once, and never hold process-local resources (temp files, open handles) across an `Await`.
- A child job is identified solely by its parent, workflow name, and arguments. Two identical `Await` calls collapse into one memoized child. To force two distinct effects, vary the arguments (e.g. add a discriminator field).

## Job Statuses

A job can be in one of the following statuses:

| Status | Meaning |
| --- | --- |
| `ready` | ready to be worked on after `next_run_at` |
| `processing` | currently being worked on |
| `sleep` | waiting for child jobs |
| `err` | recoverable error; will retry |
| `timeout` | timed out (and failed) |
| `ok` | succeeded |
| `failed` | non-recoverable failure |
| `resolved` | a human has dealt with a failure |

## The Jobcenter server

Jobcenter stores job data in a database (PostgreSQL by default) but keeps all orchestration logic in the application, not the database. This separation — dumb store, smart engine — is the central architectural choice.

The database provides **exactly two special capabilities**:

1. **Atomic claim** of the next runnable job (`FetchNextJob`).
2. **Notifications** — `LISTEN`/`NOTIFY` with a polling fallback.

Everything else the database does is plain CRUD inside transactions. All scheduling, replay, memoization, timeouts, retries, cron, sticky/greedy routing, zombie handling, and restart live in the Go engine. PostgreSQL remains the default because of its mature, type-safe networking layer, its rich query support (making all job data flexibly searchable), and `LISTEN`/`NOTIFY`. But because the database is dumb, the backend is **switchable** (see [Store interface](../03-store-interface.md)).

### Interacting with the Jobcenter server

There are two ways to interact with a Jobcenter server.

#### The "inspection interface"

To inspect the current state of the queues. This reads the **search projection** table (see [Data structures](#jobcenter-data-structures)), either directly via SQL or through the HTTP `GET /jobs` endpoint and the `jobcenter ps` CLI. Search load never touches the hot job table.

#### The "runner interface"

To enqueue or check out jobs, register runners, and report results. A Go runner uses the Jobcenter SDK, which calls a small, well-defined set of `Store` methods (notably `FetchNextJob`). Runners and workflows never touch the database any other way. Because the same operations are also exposed over HTTP, **non-Go runners are first-class**: a runner written in any language (or running where a direct database connection is undesirable) drives Jobcenter over the HTTP runner interface, exchanging protobuf payloads. The Go SDK is the most integrated path today, but it is not the only one — the runner interface is the contract, and host-language SDKs are layered on top of it.

## The Jobcenter components

A Jobcenter system consists of:

- a **store** (`store/`, `store/postgres/`) — persistence + the two special capabilities;
- an **engine** (`engine/`) — all orchestration and the runner loop;
- a **Go SDK** — typed `Workflow[Req,Resp]` / `Future[Resp]` values and the `async`/`await`/`asleep`/`alog` primitives;
- an **HTTP service** (`api/http/`) and a **CLI** (`cmd/jobcenter/`).

### Database migrations

Schema is managed with plain, idempotent SQL migrations under `store/postgres/migrations/`. Crucially, these migrations carry **only** tables and indexes — no orchestration functions or triggers, since that behaviour lives in the engine. Apply them with:

```
jobcenter db:migrate      # update to latest schema
jobcenter db:remigrate    # drop and reinstall the schema
```

The schema is versioned; `jobcenter version` prints both the binary's version and the database's schema version, which should match.

### Building a runner

A runner is a Go program that imports the Jobcenter SDK, registers its workflows, points at a database (via `DATABASE_URL` or a config file), and starts the engine. See [Golang SDK](#golang-sdk) for the full walkthrough.

## The Workflow SDK

The Go SDK provides the primitives used inside workflows.

### async

`Async` checks whether a child job with the given workflow and arguments already exists under the current job; if so it returns a handle to it, otherwise it creates one. It does **not** wait for the child to resolve — it returns a typed `Future[Resp]` immediately.

### await

`Await` resolves a child job and returns its result **directly** (no error tuple). If the child is `ok` it returns the decoded result; if the child `failed` or timed out, `Await` **panics** with the child's error; if the child is not yet resolved, it raises the pending signal so the engine suspends the current job (sets it to `sleep`) and re-runs it later. Both the failure and pending cases are panics recovered by the runner (see [Control flow](#control-flow-the-pending-signal)). Awaiting child jobs one by one has overhead — each `Await` suspends the runner — so start independent children with `Async` first and then await them, or use `Await(ctx, All)` to wait for every outstanding child at once before collecting results.

### asleep(duration)

Suspends the current workflow for a duration without blocking the runner. Never use `time.Sleep` inside a workflow — use `Asleep`, which schedules a wake-up via `next_run_at`.

### alog(msg, payload)

Appends a log entry to the `events` table. As with replay-safe side effects, a given log line is written only once per workflow and payload, regardless of how many times replay re-executes it.

### How to run things in parallel

To parallelize, put each unit of work into its own child job started with `Async`, wait for all of them with `Await(ctx, All)`, then collect results with `Await` (which now returns the memoized results without creating new children). Remember: each child's arguments must differ, or they collapse into a single memoized job.

### Unit-testing workflows

The SDK ships a test helper that runs a workflow to completion in-process against an in-memory or throwaway store, drives replay deterministically, and lets you stub child workflows and external services — so a unit test can exercise one workflow in isolation, with fakes for everything it calls out to.

### Using Jobcenter from non-runners

Client code that only enqueues or inspects workflows (not a runner) connects, enqueues, optionally processes, and awaits results — via the SDK client or the HTTP API:

- **Connect** to a Jobcenter database or HTTP endpoint.
- **Enqueue** a workflow (`Enqueue`), returning a job id.
- **Process** queues inline for scripts/tests (`ProcessAll`).
- **Await** a specific job id with a time limit.

## Jobcenter data structures

Jobcenter **splits the hot path from search** (principle 7):

### Job data

- **`jobs`** — lean, hot, authoritative. Holds identity/tree columns (`id`, `parent_id`, `root_id`, `full_id`), the immutable spec (`workflow`, `workflow_method`, `workflow_version`, `queue`, `max_attempts`, `cron`, `is_sticky`, `is_greedy`), scheduling state (`status`, `next_run_at`, `timing_out_at`, `failed_attempts`, `sticky_host_id`), and the **authoritative protobuf payloads** `args_proto` / `result_proto`, plus an `args_hash` used for memoization lookups.
- **`job_search`** — the projection used by `ps`, dashboards, and `GET /jobs`. Written in the same transaction as `jobs`, it decodes the proto payload to `args_json` and carries the caller's `tags` JSONB with GIN and expression indexes. Because it is derived, it can be rebuilt from the authoritative payloads.

### Additional job information: attached_data, tokens, xrefs

- **`attached_data`** — progress information (`completed_steps`, `total_steps`, `eta`).
- **`tokens`** — opaque tokens for externally resolved jobs.
- **`xrefs`** — `(external_system, xref)` → job mappings, unique per system.

### Orchestrating runners

- **`hosts`** — runner hosts, with `status` and `heartbeat_at` (used by the Go zombie scan).
- **`worker_sessions`** — a runner's session: which `queues` and `workflows` it serves; read when the engine builds a claim filter.

### Collecting events

- **`events`** — an append-only audit log (`job.ready`, `job.ok`, `job.failed`, `host.heartbeat`, `zombie`, …) for observability and analytics.

### Other tables

- **`registry`** — known `(workflow, version)` with their options JSON.
- **`settings`** — key/value configuration.

## Using events

The `events` table records the lifecycle of every job and host. It powers `jobcenter logs` and `jobcenter events`, and is the raw material for understanding failures, measuring throughput, and (potentially) training runtime/ETA estimates.

## Various Jobcenter features

### How Jobcenter picks a job to run

When a runner asks for work, the engine computes a **claim filter** (in Go) and the store atomically returns the single best match. A job is eligible when: it is `ready` (or `err` and due); its workflow is served by the runner; its `next_run_at` is in the past; it is not sticky to a different host; and no greedy job is already running on the host. Ties are broken by oldest `next_run_at`. The store uses `SELECT … FOR UPDATE SKIP LOCKED LIMIT 1` so a job is claimed exactly once without runners blocking on a table lock. The **policy** (sticky/greedy/queue/workflow constraints) is decided in the engine and passed to `FetchNextJob`; the SQL is pure mechanism.

### Heartbeats

A host is considered unavailable if it stops communicating for a few minutes. Long-running runners must send heartbeats; `jobcenter run:heartbeat` emits one roughly every minute, carrying basic host metrics (CPU load, etc.) into the `events` table. Heartbeats also trigger the zombie check.

### Current information

Within a job, the SDK exposes the "current context" of the enclosing public workflow (`CurrentWorkflow`, `CurrentContext`, `CurrentArgs`). The current workflow is the nearest ancestor that runs a public `run`/`call` entry point — usually the invocation expressing user intent — so private child jobs can refer to its arguments/context without re-storing them.

### Jobs that resolve externally

A job may need to be resolved by another system or by user input. Jobcenter and the external party agree on an identity, provided by either side:

1. **Jobcenter provides a token.** The workflow creates a checkpoint and obtains a token; the external service (or a user clicking a link) resolves it, e.g. via `POST /workflows/{token}/resolve`, whose body becomes the job's result. Useful when you can hand a callback URL to the external service.
2. **The external service provides an external reference.** The service supplies an id, stored in `xrefs`; a thin integration layer resolves the job when the external event arrives. `external_system` namespaces the reference.
3. **Tracking another workflow.** `Track!` enqueues another workflow as a root job and awaits it, behaving like `await` but decoupling the tracked job's hierarchy (useful around sticky/greedy constraints).

### Stock workflows

Jobcenter ships a few generally useful built-in workflows available on every runner — for example running an external command or making an HTTP request. A "run any command" workflow is powerful and a security trade-off, so it is opt-in.

### Postprocessing

A workflow may define cleanup hooks (`cleanup`, `cleanup_on_failure`, `cleanup_on_success`) that the engine enqueues as standalone root jobs after the workflow's main method resolves, via an after-completion hook in the engine.

### Queue support

A queue organizes workflows and jobs and is the unit of autoscaling. A job's queue comes from the `Enqueue` call, falling back to the workflow's registered queue, then a default. By default a child job inherits its parent's queue, but `Async`/`Await` accept a `queue:` option. A runner can be restricted to specific queues (`jobcenter run --queue=foo,bar`); by default it serves all queues for workflows it knows. The queue mapping lives in the clients/runners — they must agree on which queue serves which workflow.

### Shutting down a host

Shutdown is graceful: the host is marked `shutdown`, after which the claim filter only returns sticky/greedy jobs already bound to that host; sessions are told to stop, drain, and disconnect; when no sessions remain the host stops itself. For cloud runners this final step can trigger an actual instance shutdown.

### Host IDs

A runner picks a random UUID host id on startup, persisted locally and reused across restarts; multiple processes on the same machine/user/directory can share it. A `JOBCENTER_HOST_ID` environment variable overrides it (handy in tests and development).

### Sticky and greedy workflows

A **sticky** workflow is bound to one host: all of its jobs run there, so they can share host-local resources (e.g. a downloaded video asset). Stickiness is registered with `sticky: true` and is inherited by children. A **greedy** workflow is sticky *and* takes the whole host for the duration, which balances large workflows across hosts. Register with `greedy: true`. Usually you want greedy, not bare sticky.

### Zombies & resurrections

If the host running a sticky/greedy workflow disappears, the workflow can no longer make progress and fails with a `Zombie` error. The engine checks for zombies (at most once a minute, triggered by heartbeats) by scanning stale `heartbeat_at`. Workflows registered with `resurrect: true` are automatically restarted as a fresh instance; others are left for inspection, because blind restarts can repeat non-idempotent effects (e.g. re-sending an email).

## Workflow registration

Every workflow is registered with the system, normally when a runner starts and reports its workflows. Registration records the workflow's options so that any participant can look them up. Options used by Jobcenter: `version`, `queue`, `max_attempts`, `timeout`, `sticky`, `greedy`, `cron`, `resurrect`, and the optional `json_schema`. Arbitrary extra options may be stored for application use (e.g. an authorization requirement). A workflow is not expired when its runners disappear, so jobs can be enqueued even when no runner is currently available (during redeploys or scale-to-zero).

## Version numbers

A workflow implementation is identified by name **and** version. Multiple versions can coexist. A workflow is typically enqueued without a version; when it becomes ready, the engine selects the newest known version, and thereafter only runners offering that version pick it up. Care is needed when retiring old versions while unresolved instances still reference them.

## Exponential backoff

A job that errors is rescheduled after `backoff_basetime * 1.5^failed_attempts`, with `backoff_basetime` normally 10 seconds (scaled down dramatically in fast/test mode). By default a job fails after the third unsuccessful attempt; the `timeout` must be raised if you allow more attempts. This logic, like all scheduling, lives in the Go engine.

## Public interfaces, main methods, and visibility

### Workflow main methods

A workflow exposes one public entry point. In the Go SDK this is the typed function registered with the workflow; the protobuf request message defines its arguments.

### Visibility

Jobs carry a visibility level so listings can be filtered: root jobs (initiated externally) are visibility `0`; a workflow's main method is `1`; all other (private) jobs are `2`. This lets `ps` show only user-invoked processes, only relevant steps, or everything.

### cron jobs

A cron workflow is automatically re-enqueued after each completion. Register it with `cron: <seconds>` and enqueue it once (`jobcenter cron:enqueue --cron=300 …`); the interval is the gap between one run resolving and the next starting. Cron jobs are unique per name+arguments, enforced by the engine; disable with `jobcenter cron:disable`.

## Autoscaling support

Jobcenter exposes the queue-load signals needed for autoscaling: when a queue has many upcoming unassigned jobs it should scale up; when runners sit idle it should scale down. A local scaler can start/stop runner processes on a machine for fast reaction to spikes; a cloud scaler can map a queue name to a cloud autoscaling group and adjust desired capacity. The scaling *policy* lives alongside the deployment, driven by Jobcenter's stats.

### Recording progress, ETA, and the attached_data table

`UpdateProgress(jobID, completed, total, eta)` writes into `attached_data`. Values are not validated, but the engine guarantees step counts never decrease, so progress reported on an earlier replay pass is safely superseded by later passes.

## Jobcenter as an integration layer

How applications integrate with the service.

### HTTP enqueue and query

Applications integrate primarily over HTTP. A slim wrapper around `Enqueue` adds, per request: session lookup, authorization, optional workflow-name resolution (tenant-specific implementations with a base fallback), optional context building, and automatic tagging (e.g. `owner_id`, `affiliation_id`). Queries and status fetches honor those tags so one tenant cannot read another's workflows. The endpoints are `POST /workflows`, `GET /jobs/{id}`, `GET /jobs/{id}/await`, `GET /jobs`, and the external-resolution endpoints. See [HTTP & CLI](../05-http-and-cli.md).

### Workflow name resolution

An unqualified workflow name can resolve to a tenant-specific implementation (`Workflow::<Tenant>::Name`) and fall back to a base implementation (`Workflow::Base::Name`). This is an application-level feature layered on Jobcenter's registry.

### Job contexts

A workflow typically carries a `context` argument describing the current user; the SDK's `CurrentContext` helpers make it available to private child jobs without re-storing it on every job.

### Embedding workflows in other applications

Workflows can be defined inside a host application so they have direct access to that app's models and services. The app points its Jobcenter config at the shared database (or HTTP endpoint) and loads its workflow definitions at startup.

## Golang SDK

This section explains how we integrate workflows in Go — the **first** host-language SDK, not the only one. Jobcenter's engine and runner interface are language-neutral (see [What is Jobcenter](#what-is-jobcenter)); the Go SDK is simply the first and most integrated binding, and others can follow the same pattern over the runner interface. The goal is a typed, idiomatic API where workflow code, persisted payloads, and the HTTP surface all share one source of truth: **protobuf** — which is also what keeps the model portable across host languages.

### Defining a workflow

A workflow is a typed value parameterized by a request and a response type:

```go
type Workflow[Req, Resp any] struct {
    Name, Version string
    Options       Options // queue, timeout, max_attempts, sticky, greedy, cron, resurrect, json_schema
    Fn            func(ctx *WfContext, req Req) (Resp, error)
}

func NewWorkflow[Req, Resp any](name, version string, fn func(*WfContext, Req) (Resp, error), opts ...Option) *Workflow[Req, Resp]
func Register[Req, Resp any](wf *Workflow[Req, Resp])
```

`Req` and `Resp` may each be **either a protobuf message or a plain Go value** (a scalar, slice, struct, …). The SDK serializes them through a codec: proto messages are stored directly, while plain values are wrapped in proto well-known types (`Int64Value`, `StringValue`, `Struct`, …) — so the persisted `args_proto`/`result_proto` are always protobuf, and the cross-language wire format is preserved. The payoff is ergonomics: a workflow can declare `Resp = int64`, and `Await` returns an `int64`, so callers write `a + b` rather than unwrapping `a.Value + b.Value`. Use a hand-written proto message when the payload is structured; use a plain value when it is a scalar or a simple shape. Registration records the name, version, and options in the `registry` table.

### Spawning and awaiting children

```go
// start a child, get a typed future back (does not block)
func Async[Req, Resp any](ctx *WfContext, wf *Workflow[Req, Resp], req Req, opts ...Opt) *Future[Resp]

// resolve a future: returns the result directly.
// panics on child failure or to signal "pending" — both recovered by the runner.
func (f *Future[Resp]) Await(ctx *WfContext) Resp

// convenience: Async then Await (same panic-on-error contract)
func Call[Req, Resp any](ctx *WfContext, wf *Workflow[Req, Resp], req Req, opts ...Opt) Resp

// wait for every outstanding child before collecting results
func Await(ctx *WfContext, sel Selector) error // Selector == All
```

`Async`/`Await` look up the child by `(parent_id, args_hash)`. A resolved child returns its decoded result (memoized); a missing child is enqueued; an unresolved child suspends the parent (pending signal); a `failed`/`timeout` child panics with its error.

### Control flow: the pending signal

`Await` never returns an error — it returns the child's result directly and **panics** in the two non-success cases, both of which the runner recovers:

- **pending** — the child isn't resolved yet; the runner sets the job to `sleep` and re-runs it later.
- **child failure** — the child resolved as `failed`/`timeout`; the panic carries the child's error, and the runner fails the current job (classifying recoverable `err`, retried with backoff, vs non-recoverable `failed`).

This keeps workflow bodies linear — `a := f1.Await(ctx); b := f2.Await(ctx); return a + b` — with no error checks after every call. A workflow reports its *own* failure through the `(Resp, error)` return of its `Fn`; a child's failure propagates automatically via the panic (a workflow that wants to handle one can `recover`, but that is rare). The panic/recover machinery is entirely hidden inside the engine; workflow authors only need to remember the replay footguns above (no once-only `defer`, no host-local state across `Await`).

### Protobuf, codegen, and JSON-schema validation

- **One source of truth.** A `buf`/protoc plugin reads a proto `service` definition and generates both the typed workflow stub *and* the HTTP handler, so the wire contract and the Go API never drift.
- **Optional JSON-schema validation.** A workflow may declare a JSON schema (sidecar file or embedded); the schema is stored in the registry so every participant can validate a payload before enqueue and before result storage, even without the implementation — an extra layer on top of proto's structural typing.

### The in-workflow primitives

The SDK exposes the DSL primitives described above as functions on `*WfContext`: `Async`, `Await`, `Asleep`, `Alog`, `UpdateProgress`, plus the `CurrentWorkflow`/`CurrentContext`/`CurrentArgs` accessors and `Track!` for cross-workflow tracking.

### Running a worker

A runner is a small `main` that registers workflows and starts the engine:

```go
func main() {
    st, _ := postgres.Open(os.Getenv("DATABASE_URL"))
    eng := jobcenter.NewEngine(st)

    jobcenter.Register(Fibonacci)
    // … register the rest of this runner's workflows

    eng.Run(context.Background(), jobcenter.RunOptions{
        Queues: []string{"default"}, // omit to serve all known queues
    })
}
```

`eng.Run` is the worker loop: wait for work (notification or polling deadline) → `FetchNextJob` → execute (replay) → persist result and wake the parent. `RunOptions` covers `--count`, `--queue`, and fast mode for tests.

### Enqueuing and awaiting from clients

Non-runner code uses the typed client:

```go
client, _ := jobcenter.Dial(os.Getenv("DATABASE_URL")) // or an HTTP endpoint
id, _ := jobcenter.Enqueue(ctx, client, Fibonacci, &pb.FibReq{N: 10},
    jobcenter.WithQueue("default"), jobcenter.WithTags(map[string]string{"owner_id": "42"}))

result, err := jobcenter.AwaitJob[int64](ctx, client, id, 30*time.Second)
```

The same operations are available over HTTP for clients that are not written in Go.

### Testing workflows

```go
func TestFibonacci(t *testing.T) {
    h := jobcentertest.New(t)        // in-memory store, deterministic replay, fast mode
    h.Register(Fibonacci)
    result := jobcentertest.RunToCompletion[int64](h, Fibonacci, &pb.FibReq{N: 10})
    require.EqualValues(t, 55, result)
}
```

The helper drives replay in-process, supports stubbing child workflows and external services, and runs against a throwaway store.

## The Jobcenter CLI

`jobcenter` provides an extensive CLI. Global options include `-v/--verbose`, `-q/--quiet`, `help [subcommand]`, `top <command>` (repeatedly run a command), and `version`.

- **Database:** `db:migrate`, `db:remigrate`.
- **Cron:** `cron`, `cron:enqueue --cron=<n>`, `cron:disable`.
- **Enqueue:** `enqueue [--queue --tags --count --timeout --sticky --greedy --run-in] <workflow> [args]`, `await [--queue --tags --timeout] <workflow> [args]`.
- **Hosts:** `host:restart`, `host:shutdown`, `hosts`.
- **Sessions:** `sessions`.
- **Jobs:** `job:await`, `job:force`, `job:kill`, `job:resolve [--token --xref --external_system]`, `job:restart`.
- **Logs & status:** `logs`, `ps [--limit --queue --status --age --visibility --affiliation]`, `ps:show`, `ps:failed`, `ps:latest`, `ps:result`.
- **Registry:** `registry`, `registry:local`, `registry:show`.
- **Run:** `run [--count --queue --fast]`, `run:all`, `run:one`, `run:heartbeat`.

## Ideas for future improvements

Some of these are native to Jobcenter's design; others remain on the roadmap:

- **Jobcenter as the main HTTP interface.** Mapping HTTP routes to workflows — with session lookup, power checks, schema validation, and enqueue — is a first-class goal, and the Go HTTP service is built for the throughput it requires.
- **Hot/cold partitioning.** Only non-resolved ("hot") jobs matter for the claim query; the lean `jobs` table plus partitioning on a "cold" flag keeps claim performance flat as cold history grows.
- **Sharding.** Disjoint id ranges per shard let independent Jobcenter servers run share-nothing while keeping ids globally unique for cross-shard analysis.
- **Lean workflows.** When a whole workflow is available in the current process, run it in-process and only write summary job/events rows — avoiding round-trips for trivial workflows.
- **Step-by-step execution.** A `paused` state plus a `step`/`continue` runner mode for debugging and building new workflows.
- **Private/sensitive data.** Splitting arguments into normal vs sensitive sets (distinct columns) so PII can be scrubbed while retaining the workflow record.
- **AWS Lambda runners**, **eager jobs**, **garbage collection** of low-visibility history, and **public/private workflow** access rules.
- **JSON-schema validation** — already folded into the SDK above as an optional layer over protobuf.
