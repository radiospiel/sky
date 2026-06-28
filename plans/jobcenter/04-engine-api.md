# 04 — Engine & developer API

The engine holds all orchestration and exposes a typed, idiomatic Go API
(principle 8). This is where postjob's replay model is reimplemented.

## Typed workflows & futures

Instead of Ruby's stringly-typed `async("Fibonacci", n)` / `await(...)`,
workflows are typed values keyed to proto messages:

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

## Replay & memoization (the core)

This reimplements `runner.rb` + `find_or_create_childjob` in Go. On each wake-up
the runner re-executes the workflow's `Fn` **from the top**. `Async`/`Await`
resolve children by `(parent_id, args_hash)` via `store.FindChildJob`:

- **child resolved** → decode `result_proto` and return it (memoized);
- **child missing** → `store.EnqueueJob` to create it, then signal pending;
- **child present but unresolved** → signal pending.

When pending is signalled the runner sets the current job to `sleep` and returns;
the job re-runs later (woken by a child completing or by polling), and previously
resolved `Await`s now return their cached values — so the function resumes where
it left off. `await :all` is supported by checking
`store.ChildJobs(parentID)` for any unresolved child.

`args_hash` is a stable hash over `(workflow, method, args)` so identical child
invocations memoize to the same row (Ruby keyed on the full `args` JSON).

## Control flow: the pending signal

**Decision (recommended): `panic(pendingSignal)` recovered by the runner.**

Ruby uses `throw :pending`. The Go equivalent that keeps workflow bodies linear is
an internal panic with a sentinel value, recovered in the runner:

```go
func (r *Runner) execute(ctx *WfContext, j *store.Job) (status, payload, err) {
    defer func() {
        if v := recover(); v == pendingSignal {
            status = StatusSleep // not an error: just suspended
        } else if v != nil {
            panic(v) // real panic: propagate
        }
    }()
    resp, err := r.registry.invoke(ctx, j) // may panic(pendingSignal)
    ...
}
```

`Await` panics with `pendingSignal` when a child is unresolved. The public
`(Resp, error)` return is reserved for **real** workflow errors, which the runner
classifies as recoverable (`err`, retried with backoff) or non-recoverable
(`failed`) — mirroring `on_exception`/`should_retry?` in `runner.rb`. The
panic/recover is fully hidden inside the engine.

*Alternative considered:* thread an explicit `ErrPending` through every call. It
avoids panic but forces `if err == ErrPending { return }` after every `Await`,
making workflow bodies noisy and easy to get wrong. Rejected. (Flagged as an open
decision in [06-roadmap.md](06-roadmap.md).)

## Orchestration (moved from PL/pgSQL to Go)

Run by the runner's after-completion hook and a maintenance loop (single-flighted
across workers via a Postgres advisory lock):

- **Timeouts** — scan `timing_out_at`, mark `timeout`, rerun with backoff
  (`_process_timedout_jobs` / `_set_job_timeout`).
- **Backoff** — `base * 1.5^failed_attempts`, `base` smaller in fast/test mode
  (`_initiate_rerun_on_error`).
- **Cron** — on completion of a cron root, re-enqueue at `now + cron`
  (`_restart_cronjob`); `disable`/`has_active` helpers in Go.
- **Sticky/greedy** — engine fills `ClaimFilter.StickyHostID` / `GreedyRootID`
  per session+host (logic from `_upcoming_runnable_job`).
- **Zombie** — scan stale `hosts.heartbeat_at`; for sticky trees fail/restart,
  else rerun with backoff (`zombie_check` / `_set_job_zombie`).
- **Restart/resurrect** — clone the root job into a pristine `ready` copy, set
  `restarted_job_id` on the original (`job_restart`).
- **Post-processing & parent wake** — after a child completes, wake the parent
  (set `ready`, notify) and enqueue any registered post-processing workflow
  (`_after_job_completed`); resolve `tracked_by` parents.

## Protobuf, codegen & validation

- **Serialization (principle 1):** workflow `Req`/`Resp` are proto messages; their
  serialized bytes are stored in `args_proto`/`result_proto` as the source of
  truth (replacing the JSON `encoder.rb`).
- **Codegen (principle 8):** a `buf`/protoc plugin reads a proto `service`
  definition and generates, from one source: (a) the typed `Workflow[Req,Resp]`
  registration stub and (b) the HTTP handler. Workflow code and the HTTP surface
  can never drift apart.
- **JSON-schema validation (principle 2):** an optional per-workflow JSON schema
  is checked against the decoded message before enqueue and before result storage
  — extra validation on top of proto's structural typing.
