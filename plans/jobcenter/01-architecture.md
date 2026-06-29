# 01 — Architecture

Jobcenter is layered so that **every orchestration decision is made in Go** and the database is reduced to a swappable store. There are three layers.

## Layers

### 1. Store (`store/`, `store/postgres/`)

DB-agnostic persistence. Exposes plain CRUD + transactions, plus exactly two "special" capabilities (see principle 6):

- **`FetchNextJob`** — atomically select, lock and mark-as-processing the next runnable job that matches a filter computed by the engine.
- **`Notifier`** — wake-ups via LISTEN/NOTIFY, with a polling fallback.

No business logic, no PL/pgSQL orchestration functions. See [03-store-interface.md](03-store-interface.md).

### 2. Engine (`engine/`)

All orchestration:

- **Registry** of typed workflows (name + version → handler + options).
- **Runner**: the worker loop — wait for work, claim a job, execute, persist.
- **Replay & memoization**: re-run the workflow body from the top, resolving child jobs from cache (the core of postjob).
- **Futures**: typed `Future[Resp]` returned by `Async`, awaited later.
- **Scheduler / maintenance**: timeouts, exponential backoff, cron re-enqueue, sticky/greedy routing, zombie detection, restart/resurrect, post-processing.

See [04-engine-api.md](04-engine-api.md).

### 3. Edges (`api/`, `cmd/jobcenter/`)

- **Server (ConnectRPC)** — the engine + store run inside a server that exposes a [ConnectRPC](https://connectrpc.com) API (protobuf and JSON). This server is the **mandatory connection point**: every runner and client talks to it, and it is the only component that touches the database. Runners execute workflow code (replay) locally and exchange jobs/results with the server; they never open a DB connection.
- **CLI** covering the existing verbs (`serve`, `run`, `enqueue`, `await`, `ps`, `registry`, `job:*`, `cron`, `db:migrate`, `hosts`, `sessions`, `events`). All but `serve`/`db:*` are ConnectRPC clients of a server.

See [05-http-and-cli.md](05-http-and-cli.md).

## What moves out of the database

In Ruby these are PL/pgSQL; in Jobcenter they become Go:

| Ruby PL/pgSQL | Jobcenter (Go) |
| --- | --- |
| `checkout` + `_upcoming_runnable_job` | `engine` computes a `ClaimFilter`; `store.FetchNextJob` does the atomic select/lock/mark only |
| `find_or_create_childjob` (memoization) | `engine` replay using `store.FindChildJob(parentID, argsHash)` + `EnqueueJob` |
| `_process_timedout_jobs` / `_set_job_timeout` | maintenance loop scans `timing_out_at` |
| `_initiate_rerun_on_error` (backoff) | `base * 1.5^failed_attempts` in Go |
| `_restart_cronjob` | engine re-enqueues on cron-root completion |
| `zombie_check` / `_set_job_zombie` | maintenance loop scans stale `hosts.heartbeat_at` |
| `job_restart` | engine clones the root job |
| `_after_job_completed` (post-proc, parent wake, tracking) | engine after-completion hook |

## What stays in the database

Only the two special capabilities (principle 6):

- **Atomic claim** — `SELECT … FOR UPDATE SKIP LOCKED LIMIT 1` + mark processing, in one transaction.
- **Notifications** — `pg_notify` issued explicitly by Go after commits (no triggers), `LISTEN` on the worker side, and a `MIN(next_run_at, timing_out_at)` query to compute the polling deadline.

Everything else the store does is ordinary `INSERT`/`UPDATE`/`SELECT` inside transactions.

## Package layout

```
jobcenter/
  proto/            workflow .proto defs + buf config
  gen/              generated Go (messages, workflow stubs, http handlers)
  engine/           runner, replay, futures, registry, scheduler/maintenance
  store/            Store interface + Job model (DB-agnostic)
  store/postgres/   PostgresStore: FetchNextJob, notifications, migrations
  api/              ConnectRPC server (protobuf + JSON); the runner/client API
  cmd/jobcenter/    CLI
  examples/         typed fibonacci/sum/sleeping_beauty equivalents
```

## Design invariants

- The engine never embeds logic in SQL; the store never makes scheduling decisions.
- The store is replaceable: anything implementing the `Store` interface (notably `FetchNextJob`) can back the engine. Postgres is the preferred, fully-featured backend; other databases degrade to poll-only notifications.
- Proto bytes on the `jobs` table are the source of truth; the `job_search` projection is derived and may be rebuilt.
