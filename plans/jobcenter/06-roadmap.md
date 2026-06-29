# 06 — Roadmap, parity map & open decisions

## Milestones

1. **Store + schema**
   - Migrations: status enum, `jobs`, `job_search`, supporting tables, indexes.
   - `Store` interface + `Job`/`JobView` models.
   - `PostgresStore`: `FetchNextJob` (atomic claim), enqueue/CRUD in `WithTx`, `Notifier` (LISTEN/NOTIFY + `NextDeadline` polling).
   - *Exit:* enqueue a row, claim it from a second connection, observe a wake-up.

2. **Engine core**
   - Registry; runner loop (wait → claim → execute → persist).
   - Replay + memoization via `FindChildJob(parentID, argsHash)`.
   - Typed `Workflow[Req,Resp]` / `Future[Resp]`; pending control flow.
   - *Exit:* the Fibonacci example computes correctly via replay.

3. **Proto + codegen**
   - Proto messages + service defs; `buf` plugin generating workflow stubs + HTTP handlers; optional JSON-schema validation hook.
   - *Exit:* a workflow + its HTTP endpoint generated from one `.proto`.

4. **Orchestration**
   - Timeouts, backoff, cron, sticky/greedy `ClaimFilter`, zombie, restart, post-processing/tracking, maintenance single-flight (advisory lock).
   - *Exit:* timeout, retry-with-backoff, cron re-enqueue and zombie reclaim all covered by tests.

5. **HTTP API + CLI**
   - Server (client + runner/session endpoints); CLI verbs.
   - *Exit:* enqueue + await + ps over HTTP and CLI against a real Postgres.

6. **Examples + tests**
   - Typed fibonacci/sum/sleeping_beauty; parity tests vs Ruby semantics; a poll-only non-Postgres store stub proving switchability.

## Ruby → Go parity map

| Ruby source | Jobcenter location |
| --- | --- |
| `runner.rb` (replay, await, on_exception) | `engine/runner.go`, `engine/replay.go` |
| `find_or_create_childjob`, `008a_childjobs.sql` | `engine` + `store.FindChildJob` |
| `checkout`, `_upcoming_runnable_job` (`013a`) | `store.FetchNextJob` + `ClaimFilter` |
| `notifications.rb`, `005_helpers.sql` triggers | `store/postgres` `Notifier` (NOTIFY from Go) |
| `_process_timedout_jobs`, `_set_job_timeout` | `engine/maintenance.go` (timeouts) |
| `_initiate_rerun_on_error` (backoff) | `engine` backoff |
| `_restart_cronjob` (`021`) | `engine` cron |
| `zombie_check`, `_set_job_zombie` (`023a`) | `engine/maintenance.go` (zombie) |
| `job_restart` (`040`) | `engine` restart |
| `_after_job_completed` (`005`) | `engine` after-completion hook |
| `encoder.rb` (JSON) | proto (`args_proto`/`result_proto`) |
| `registry.rb`, `registry` table | `engine/registry.go` + `registry` table |
| `interface.rb`, JC HTTP endpoints | `api/http` |
| `cli/*` | `cmd/jobcenter` |
| `003_postjobs.sql` wide table | split `jobs` + `job_search` |

## Open decisions

- **Pending-signal mechanism** — `panic(pendingSignal)`/recover (recommended, keeps workflow bodies linear) vs explicit `ErrPending` return (noisier). See [04-engine-api.md](04-engine-api.md).
- **`args_hash` input** — hash canonical JSON of the decoded message (stable across proto field reordering, matches Ruby's args-equality) vs hash raw proto bytes (cheaper but order-sensitive). Leaning canonical JSON.
- **`visibility` levels & `events` audit log** — preserve the Ruby `visibility` smallint and full event stream in v1, or defer the audit log to a later milestone? Affects `ps` filters and observability.
- **Remote-worker model** — first-class HTTP-driven workers in v1, or DB-direct workers only with HTTP for clients? Impacts how much of the session/host surface ships in milestone 5.
- **Greedy semantics** — confirm the Ruby rule (one greedy root per sticky host; `control` queue always allowed through) is exactly what we want, or simplify.
- **Failure propagation relies on host-language exceptions (limitation).** `Await` returns the value directly and a failed/timeout child propagates by panicking out of it. This means a host language either needs exceptions/panics, or needs an async primitive whose failure aborts execution at the await point. In Go this is fully handled inside the SDK (panic/recover), so it is transparent to workflow authors; it matters only for future non-Go SDKs. See [04-engine-api.md](04-engine-api.md#limitation-failure-propagation-relies-on-host-language-exceptions).
