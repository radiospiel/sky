# 05 — HTTP interface & CLI

Jobcenter keeps the existing operational surface so current callers and operators feel at home. The HTTP contract mirrors `lib/postjob/queue/interface.rb` and the JC endpoints documented in `doc/book.md`; the CLI mirrors `lib/postjob/cli/`.

## HTTP service (`api/http`)

The core gem had no built-in HTTP server — it defined an abstract interface (`interface.rb`) and the JC app exposed it over HTTP. Jobcenter ships that server.

### Client / workflow endpoints

| Method & path | Maps to | Purpose |
| --- | --- | --- |
| `POST /workflows` | `session_enqueue_job` / `enqueue` | Enqueue a workflow. Body is proto (preferred) or JSON; returns job id, or `30x` to the status URL. |
| `GET /jobs/{id}` | `find_job` | Status + result (decoded from `result_proto`). |
| `GET /jobs/{id}/await` | `job_await` | Long-poll until terminal or `time_limit`; backed by the per-job completion channel. |
| `GET /jobs` | `ps` | Search/list via the `job_search` projection (filter by queue, status, workflow, tags, age, limit). |
| `POST /workflows/{token}/resolve` | `resolve_job` (token) | Resolve a manual/external job by token. |
| `POST /jobs/resolve` | `resolve_job` (xref) | Resolve by `{external_system, xref}`. |
| `POST /jobs/{id}/restart` | `session_restart_job` | Restart a failed/timed-out/resolved root job. |
| `POST /jobs/{id}/progress` | `update_progress` | Report `completed_steps`/`total_steps`/`eta`. |

`resolve` bodies follow the existing shape: `{value: …}` on success or `{error, error_message, error_backtrace}` on failure.

### Runner / session endpoints (for remote workers)

For workers that don't talk to the DB directly — they drive the engine over HTTP:

| Path | Maps to |
| --- | --- |
| `POST /hosts` | `host_register` |
| `POST /hosts/{id}/heartbeat` | `host_heartbeat` |
| `POST /hosts/{id}/shutdown` | `host_shutdown` |
| `POST /sessions` | `host_start_session` |
| `POST /sessions/{id}/checkout` | `session_checkout_job` (→ `FetchNextJob`) |
| `GET /sessions/{id}/wait` | `session_wait_for_job` (notify + poll) |
| `POST /sessions/{id}/jobs/{id}/resolve` | `resolve_job` |

The HTTP handlers are generated from proto service definitions alongside the workflow stubs (see [04-engine-api.md](04-engine-api.md)), so the wire contract and the typed workflow API share one source of truth.

## CLI (`cmd/jobcenter`)

Covers the verbs in `lib/postjob/cli/`:

- **Run:** `run [--queue …] [--count N] [--fast]`, `run:all`, `run:one`.
- **Enqueue:** `enqueue <Workflow> [args] [--queue --tags --timeout --sticky --greedy --run-in --count]`, `await <Workflow> [args] [--timeout]`.
- **Inspect:** `ps`, `ps:failed`, `ps:full`, `ps:result`, `ps:show`, `ps:stats`, `logs`, `events`, `top`.
- **Jobs:** `job:resolve`, `job:restart`, `job:kill`, `job:await`, `job:force`.
- **Cron:** `cron`, `cron:enqueue --cron=N`, `cron:disable`.
- **Registry:** `registry`, `registry:local`, `registry:show`.
- **DB:** `db:migrate`, `db:remigrate`, `db:drop`.
- **Infra:** `hosts`, `host:shutdown`, `sessions`, `version`.

Read paths (`ps`, `registry`) query the `job_search` projection; mutating paths go through the engine so orchestration stays in one place.
