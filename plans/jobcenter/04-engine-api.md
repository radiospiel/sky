# 04 — Engine & developer API

The engine holds all orchestration and exposes a typed, idiomatic Go API (principle 8). This is where postjob's replay model is reimplemented.

## Typed workflows & futures

Instead of Ruby's stringly-typed `async("Fibonacci", n)` / `await(...)`, workflows are typed values keyed to proto messages:

```go
type Workflow[Req, Resp proto.Message] struct {
    Name, Version string
    Options       Options // queue, timeout, max_attempts, sticky, greedy, cron, ...
    Fn            func(ctx *WfContext, req Req) (Resp, error)
}

func Register[Req, Resp proto.Message](wf *Workflow[Req, Resp])

// spawn a child, get a typed future back (does not block)
func Async[Req, Resp proto.Message](ctx *WfContext, wf *Workflow[Req, Resp], req Req, opts ...Opt) *Future[Resp]

// resolve a future; returns the memoized result or signals pending
func (f *Future[Resp]) Await(ctx *WfContext) (Resp, error)

// convenience: Async then Await
func Call[Req, Resp proto.Message](ctx *WfContext, wf *Workflow[Req, Resp], req Req, opts ...Opt) (Resp, error)
```

### Example — Fibonacci (cf. `examples/fibonacci.rb`)

```go
var Fibonacci = &Workflow[*pb.FibReq, *pb.FibResp]{
    Name: "Fibonacci", Version: "1.0",
    Fn: func(ctx *WfContext, req *pb.FibReq) (*pb.FibResp, error) {
        if req.N <= 2 {
            return &pb.FibResp{Value: 1}, nil
        }
        f1 := Async(ctx, Fibonacci, &pb.FibReq{N: req.N - 2})
        f2 := Async(ctx, Fibonacci, &pb.FibReq{N: req.N - 1})
        a, _ := f1.Await(ctx)
        b, _ := f2.Await(ctx)
        return &pb.FibResp{Value: a.Value + b.Value}, nil
    },
}
```

The body reads linearly, exactly like the Ruby original.

## Worker and server: who does what

Two processes cooperate:

- The **worker** (runner) hosts the workflow code and executes the `Fn`. It holds no orchestration state and never touches the database.
- The **server** owns the engine: the durable job state, child find-or-create, memoization, suspend/resume, and all scheduling. It is the only thing that talks to the store (this reimplements `runner.rb`'s bookkeeping + `find_or_create_childjob`).

Every in-workflow primitive the `Fn` calls (`Async`, `Await`, `Asleep`, `Alog`, …) is a **ConnectRPC call to the server**. The worker is deliberately thin.

## Replay & memoization (the core)

On each attempt the worker re-executes the workflow's `Fn` **from the top**. The primitives drive the server:

- `Async(child)` → RPC: the server find-or-creates a child keyed by `(parent_id, args_hash)` and returns a handle. `args_hash` is a stable hash over `(workflow, method, args)`, so identical invocations memoize to the same row.
- `Await(handle)` → RPC: the server resolves the child and replies with one of
  - **resolved** (`ok`) → the decoded `result_proto` (memoized);
  - **failed/timeout** → the child's error;
  - **pending** → not resolved yet.

On *pending*, the worker stops executing this attempt and acks. The server has the child recorded and reschedules the parent when the child completes; a worker (any worker) then re-runs the `Fn` from the top, and the now-resolved `Await`s return their memoized results from the server until execution reaches the new frontier — so the function resumes where it left off. `await :all` is one RPC the server answers by checking the parent's children for any unresolved one.

## Control flow: the pending signal

**Decision (recommended): `panic(pendingSignal)` recovered by the worker.** The unwinding has to happen where the `Fn` runs — on the worker — so this is worker-side, even though the *decision* (resolved/failed/pending) comes from the server:

```go
// in the worker: run one attempt of a job's Fn
func (w *Worker) execute(ctx *WfContext, j *Job) (outcome, error) {
    defer func() {
        if v := recover(); v == pendingSignal {
            // server said a child is pending; just stop this attempt
        } else if v != nil {
            panic(v) // real panic: propagate
        }
    }()
    return w.registry.invoke(ctx, j) // may panic(pendingSignal) from inside Await
}

// Await: one RPC to the server, translated into a value or an unwind
func (f *Future[Resp]) Await(ctx *WfContext) Resp {
    r := ctx.server.ResolveChild(ctx, f.handle) // ConnectRPC
    switch r.State {
    case Resolved: return decode[Resp](r.Result)
    case Failed:   panic(childError{r.Error})   // recovered → job fails
    default:       panic(pendingSignal)          // recovered → attempt suspends
    }
}
```

`Await` returns the child's result directly (no error tuple) and **panics** in the two non-success cases. The server classifies a real failure as recoverable (`err`, retried with backoff) or non-recoverable (`failed`); a workflow reports its *own* failure via the `(Resp, error)` return of its `Fn`. The panic/recover is hidden inside the worker SDK.

*Alternative considered:* thread an explicit `ErrPending` through every call. It avoids panic but forces `if err == ErrPending { return }` after every `Await`, making workflow bodies noisy and easy to get wrong. Rejected. (Flagged as an open decision in [06-roadmap.md](06-roadmap.md).)

### Limitation: failure propagation relies on host-language exceptions

Because a `failed`/`timeout` child surfaces by **panicking out of `Await`** (carrying the child's error), aborting the workflow at that point depends on the host language having exceptions/panics. Two consequences:

- In Go — and any host language with exceptions — the SDK handles this transparently via `recover`: workflow authors write linear code, and a child failure aborts execution at the `Await` call site automatically.
- A host language **without** exceptions cannot abort mid-function this way. There, the model needs an async primitive whose failure short-circuits execution at the await point (an `Await` the runtime treats as a checkpoint), rather than a thrown error.

This is a limitation to keep in mind for future non-Go SDKs (see [host-language neutrality](README.md)); within an exception/panic-capable host it is fully handled by the SDK, not by workflow authors.

## Orchestration (moved from PL/pgSQL to Go)

Run server-side by an after-completion hook and a maintenance loop (single-flighted across server nodes via a Postgres advisory lock):

- **Timeouts** — scan `timing_out_at`, mark `timeout`, rerun with backoff (`_process_timedout_jobs` / `_set_job_timeout`).
- **Backoff** — `base * 1.5^failed_attempts`, `base` smaller in fast/test mode (`_initiate_rerun_on_error`).
- **Cron** — on completion of a cron root, re-enqueue at `now + cron` (`_restart_cronjob`); `disable`/`has_active` helpers in Go.
- **Sticky/greedy** — engine fills `ClaimFilter.StickyHostID` / `GreedyRootID` per session+host (logic from `_upcoming_runnable_job`).
- **Zombie** — scan stale `hosts.heartbeat_at`; for sticky trees fail/restart, else rerun with backoff (`zombie_check` / `_set_job_zombie`).
- **Restart/resurrect** — clone the root job into a pristine `ready` copy, set `restarted_job_id` on the original (`job_restart`).
- **Post-processing & parent wake** — after a child completes, wake the parent (set `ready`, notify) and enqueue any registered post-processing workflow (`_after_job_completed`); resolve `tracked_by` parents.

## Protobuf, codegen & validation

- **Serialization (principle 1):** workflow `Req`/`Resp` are proto messages; their serialized bytes are stored in `args_proto`/`result_proto` as the source of truth (replacing the JSON `encoder.rb`).
- **Codegen (principle 8):** a `buf`/protoc plugin reads a proto `service` definition and generates, from one source: (a) the typed `Workflow[Req,Resp]` registration stub and (b) the HTTP handler. Workflow code and the HTTP surface can never drift apart.
- **JSON-schema validation (principle 2):** an optional per-workflow JSON schema is checked against the decoded message before enqueue and before result storage — extra validation on top of proto's structural typing.
