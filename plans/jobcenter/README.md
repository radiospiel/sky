# Jobcenter

A Go reimplementation of [`postjob`](https://github.com/mediafellows/postjob) — a restartable, asynchronous, distributed **workflow engine**.

## Why

`postjob` (Ruby + PostgreSQL) lets you write workflows as ordinary code. Its defining trick is **replay-based orchestration**: child jobs are memoized by `(parent_id, workflow, method, args)`, and the parent function is re-run from the top whenever a child resolves — completed `await`s return their cached result, so execution resumes where it left off. This gives durable, restartable workflows without a decider/activity DSL.

Two problems motivate the rewrite:

1. **Performance & portability.** The Ruby runner talks directly to Postgres, and the heavy lifting lives in PL/pgSQL. A Go implementation gives much better performance and a single static binary. (The Ruby docs themselves note "an implementation in Golang or Elixir should provide much better performance".)
2. **Orchestration trapped in the database.** Replay, timeouts, cron, sticky/greedy routing, zombie detection and restart are all PL/pgSQL functions (`checkout`, `_upcoming_runnable_job`, `_process_timedout_jobs`, `_restart_cronjob`, `zombie_check`, `job_restart`, `_after_job_completed`, …). That makes the logic hard to test, evolve and port to other databases.

**Jobcenter** keeps the replay model and the existing HTTP/CLI surface, but moves all orchestration into Go and reduces the database to a dumb, swappable store.

## Principles

From the original brief:

1. **Protobuf** for workflow arguments and return values.
2. Optionally allow **JSON-schema** as extra validation.
3. An **HTTP interface** similar to the one we already have (`lib/postjob/queue/interface.rb` + the documented JC endpoints).
4. **Switchable databases**, preferring Postgres. A DB handler **must implement a `FetchNextJob` method**, with a Postgres-specific implementation.

From the directional revision:

5. **Orchestration logic leaves the database.** Replay, child memoization, timeouts, cron, sticky/greedy policy, cleanup, zombie detection and restart all move into Go. We do **not** port the big SQL functions.
6. **The DB provides exactly two special capabilities:** (a) notifications (LISTEN/NOTIFY with a polling fallback) and (b) atomically claiming the next matching job. Everything else is plain CRUD + transactions.
7. **Split the tables:** authoritative proto payloads on a lean, hot job table; the JSON projection used for searching lives in a separate table.
8. **Idiomatic Go API:** typed `Workflow[Req,Resp]` values with `Future[Resp]` instead of stringly-typed calls, plus optional **codegen from proto** so workflow stubs and the ConnectRPC server share one source of truth.

## Architecture at a glance

```
 runners (Go SDK / other langs)      clients & CLI
            \                            /
             \   ConnectRPC API         /
              \  (protobuf + JSON)     /
               v                      v
        ┌──────────────────────────────────┐
        │  server (api/)                    │
        │  engine (orchestration)          │   scheduling/claim, memoization,
        │  registry, scheduler/maintenance │   timeouts, cron, sticky/greedy,
        │                                  │   backoff, zombie, restart
        └──────────────────────────────────┘
                     │  Store interface
                     v
        ┌───────────────────────────┐
        │  store (CRUD + 2 specials) │  FetchNextJob (atomic claim)
        │  store/postgres            │  Notifier (LISTEN/NOTIFY + poll)
        └───────────────────────────┘
```

Runners execute workflow code (replay) in-process and exchange jobs/results with the server over the ConnectRPC API; only the server touches the database.

Hard rule: **all business/orchestration logic lives in Go**; the store only does CRUD, transactions, atomic claim, and wake-ups.

## Document index

| Doc | Contents |
| --- | --- |
| [01-architecture.md](01-architecture.md) | Layering, package layout, what's in Go vs the DB |
| [02-data-model.md](02-data-model.md) | The two-table split, schema, indexes, migrations |
| [03-store-interface.md](03-store-interface.md) | `Store` interface, `FetchNextJob`, notifications, Postgres impl, switchability |
| [04-engine-api.md](04-engine-api.md) | Typed `Workflow[Req,Resp]`/`Future[Resp]`, replay, control flow, proto + codegen, validation |
| [05-http-and-cli.md](05-http-and-cli.md) | HTTP endpoints mirroring the existing interface, CLI |
| [06-roadmap.md](06-roadmap.md) | Milestones, sequencing, open decisions, Ruby→Go parity map |

## Status

Planning. No application code yet — this directory is the design of record.
