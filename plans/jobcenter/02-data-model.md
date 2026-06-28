# 02 — Data model

The Ruby implementation keeps everything on one wide `postjob.postjobs` table
(`lib/postjob/queue/postgres/migrations/003_postjobs.sql`, `doc/structure.sql`):
job spec, scheduling state, JSON `args`/`results`, error backtrace, and a `tags`
JSONB column with GIN + expression indexes for searching.

Jobcenter **splits this in two** (principle 7): a lean hot table holding
authoritative proto payloads, and a separate projection table for searching.

## `jobs` — lean, hot, authoritative

Only what the claim/scheduler hot path needs. Payloads are protobuf bytes.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigserial PK | |
| `parent_id` | bigint | tree edge; `ON DELETE CASCADE` |
| `root_id` | bigint | top of the workflow tree |
| `full_id` | varchar | dotted path, e.g. `1.4.9` |
| `workflow` | varchar | e.g. `Fibonacci` |
| `workflow_method` | varchar | `run` / `call` / step name |
| `workflow_version` | varchar | resolved at claim time (empty = latest) |
| `queue` | varchar | |
| `max_attempts` | int | |
| `cron` | int | seconds, or NULL |
| `is_sticky` | bool | |
| `is_greedy` | bool | |
| `args_proto` | bytea | **authoritative** input payload |
| `result_proto` | bytea | **authoritative** result payload |
| `args_hash` | varchar | stable hash of `(workflow, method, args)` for memoization |
| `status` | enum | `ready, sleep, processing, err, timeout, failed, ok, resolved` |
| `next_run_at` | timestamptz | when it becomes runnable |
| `timing_out_at` | timestamptz | deadline |
| `failed_attempts` | int | |
| `sticky_host_id` | uuid | locked host once started |
| `last_worker_session_id` | uuid | |
| `tracked_by` | bigint | parent job for external tracking |
| `restarted_job_id` | bigint | set on the original when restarted |
| `error` / `error_message` | varchar | |
| `error_backtrace_proto` | bytea | |
| `created_at` / `updated_at` | timestamptz | |

Spec columns (`workflow`, `workflow_method`, `queue`, `max_attempts`, `cron`,
`is_sticky`, `is_greedy`, `args_proto`, `args_hash`) are immutable after enqueue;
the rest is mutable scheduling/result state — mirroring the read-only vs mutable
split in `job.rb`.

### Indexes (hot path)

- Partial: `(queue, next_run_at) WHERE status IN ('ready','err')` — the claim query.
- `(root_id, id)` — tree/listing (mirrors `postjobs_root_id_and_id_idx`).
- `(parent_id, args_hash)` — child memoization lookup.
- `(timing_out_at) WHERE status IN ('ready','err','sleep')` — timeout scan.

## `job_search` — projection for queries

Written in the **same transaction** as the `jobs` row, derived from the proto
payload + caller-supplied tags. Used by `ps`, dashboards and the HTTP search
endpoint, so search load never touches the hot table.

| Column | Type | Notes |
| --- | --- | --- |
| `job_id` | bigint PK/FK → `jobs` | `ON DELETE CASCADE` |
| `workflow` | varchar | |
| `queue` | varchar | |
| `status` | enum | denormalized for filtering |
| `root_id` | bigint | |
| `created_at` | timestamptz | |
| `tags` | jsonb | caller metadata |
| `args_json` | jsonb | proto decoded to JSON for human/search use |

### Indexes

- GIN on `tags` (`jsonb_path_ops`) — matches `postjobs_tags_idx`.
- Expression: `(tags->>'owner_id')`, `(tags->>'affiliation_id')` — match
  `postjobs_tags_owner_idx` / `postjobs_tags_affiliation_idx`.
- `(workflow)`, `(queue)`, `(status)`, `(root_id)` as needed for `ps` filters.

Because `job_search` is derived, it can be dropped and rebuilt from `jobs` proto
payloads if the projection schema changes.

## Supporting tables (plain CRUD)

Carried over, minimal, **no PL/pgSQL functions** — migrations create tables +
indexes only:

- `worker_sessions` — `id`, `host_id`, `workflows[]`, `queues[]`, `status`,
  `fast_mode`. Read when building a `ClaimFilter`.
- `hosts` — `id`, `status` (`running/shutdown/stopped`), `heartbeat_at`. Used by
  the Go zombie scan; **no sentinel-row global lock** (Ruby's `checkout` locked a
  null-uuid row — Jobcenter relies on `SKIP LOCKED` instead).
- `tokens` — external/manual job resolution by token.
- `xrefs` — `(external_system, xref)` → job, unique.
- `events` — append-only audit log (`job.*`, `host.*`, `zombie`, heartbeats).
- `registry` — `workflow`, `version`, `options` JSONB (queue, max_attempts,
  timeout, sticky, greedy, cron, post_processing, resurrect).
- `settings` — key/value.

## Status enum

Preserve the Ruby lifecycle (`002_statuses.sql` + `resolved`):

```
ready → processing → ok | failed | timeout
err   → processing → …
sleep → ready → processing
resolved   (human-handled terminal state)
```

## Migrations

`store/postgres/migrations/` carries plain DDL: the enum, the two job tables, the
supporting tables, and indexes. Crucially it carries **none** of the orchestration
functions/triggers from the Ruby `migrations/` tree — that behaviour now lives in
`engine/`.
