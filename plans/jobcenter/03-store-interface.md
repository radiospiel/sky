# 03 — Store interface

The store is the only thing that touches the database. It offers plain CRUD + transactions, plus the two special capabilities from principle 6. Databases are switchable behind this interface (principle 4); Postgres is the preferred backend.

## The interface

```go
package store

type Store interface {
    // --- plain CRUD + transactions ---
    WithTx(ctx context.Context, fn func(tx Tx) error) error
    EnqueueJob(ctx context.Context, j *Job) (int64, error)
    GetJob(ctx context.Context, id int64) (*Job, error)
    UpdateJob(ctx context.Context, j *Job) error

    // memoization lookup for replay (parent_id + args_hash)
    FindChildJob(ctx context.Context, parentID int64, argsHash string) (*Job, error)
    ChildJobs(ctx context.Context, parentID int64) ([]*Job, error)

    // search/listing via the job_search projection
    ListJobs(ctx context.Context, q JobQuery) ([]JobView, error)

    // --- special capability #1: atomic claim ---
    // The engine computes policy (queues, workflows, sticky host, greedy root)
    // and passes it in. The store only does the atomic select+lock+mark.
    FetchNextJob(ctx context.Context, f ClaimFilter) (*Job, error)

    // --- special capability #2: wake-ups ---
    Notifier() Notifier
}

type ClaimFilter struct {
    SessionID    uuid.UUID
    Queues       []string   // session.queues
    Workflows    []string   // "name/version" the session can run
    Statuses     []Status   // typically {ready, err}
    StickyHostID uuid.UUID  // host affinity; zero = none
    GreedyRootID *int64     // if a greedy tree is running on this host, restrict to it
    Now          time.Time
}

type Notifier interface {
    Listen(ctx context.Context, channels ...string) (<-chan Notification, error)
    Notify(ctx context.Context, channel, payload string) error
    // NextDeadline returns when the next job becomes runnable or times out,
    // for the polling fallback (replaces Ruby time_to_next_job).
    NextDeadline(ctx context.Context, f ClaimFilter) (time.Time, bool, error)
}
```

`FetchNextJob` is the named, required method called out in principle 4.

## Postgres implementation (`store/postgres`)

### Atomic claim

A single query replaces Ruby's `checkout` + `_upcoming_runnable_job`. The sticky/greedy **policy** is decided in Go and arrives as `ClaimFilter` fields; the SQL is pure mechanism:

```sql
WITH next AS (
  SELECT id
  FROM jobs
  WHERE status = ANY($statuses)
    AND next_run_at <= $now
    AND queue = ANY($queues)
    AND (workflow || '/' || workflow_version) = ANY($workflows)
    AND ( $sticky_host = '00000000-…'::uuid
          OR sticky_host_id IS NULL
          OR sticky_host_id = $sticky_host )
    AND ( $greedy_root IS NULL
          OR root_id = $greedy_root
          OR queue = 'control' )
  ORDER BY next_run_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
UPDATE jobs SET
  status = 'processing',
  last_worker_session_id = $session,
  next_run_at = NULL,
  sticky_host_id = CASE WHEN is_sticky THEN $host ELSE sticky_host_id END,
  error = NULL, error_message = NULL, error_backtrace_proto = NULL,
  updated_at = now()
FROM next
WHERE jobs.id = next.id
RETURNING jobs.*;
```

`FOR UPDATE SKIP LOCKED` provides concurrency safety without the global sentinel lock the Ruby version took on `hosts`.

### Notifications

- **Wake on new work:** after committing an enqueue or a transition into `ready`/`err`, Go calls `Notifier.Notify(ctx, "jobs", queue)`. Workers `LISTEN` on `"jobs"` and filter by their queues. (Ruby used DB triggers `_wakeup_runners`; Jobcenter issues the `NOTIFY` from Go, so the DB has no trigger logic.)
- **Wake on completion:** `Await`/HTTP long-poll listen on a per-job channel `jobs_completed_<id>`; Go notifies it after a job reaches a terminal status.
- **Polling fallback:** `NextDeadline` runs `SELECT min(...) FROM (next_run_at of runnable; timing_out_at of unresolved)`; the worker waits until then if no notification arrives (replaces `time_to_next_job`).

### Transactions & the projection

`EnqueueJob`/`UpdateJob` write the `jobs` row and the matching `job_search` row in the same `WithTx` block, so the projection is always consistent with the authoritative payload.

## Other databases (switchability)

A backend that cannot do `LISTEN/NOTIFY` (e.g. SQLite, MySQL) still satisfies the interface:

- `FetchNextJob`: same select-lock-mark pattern using that engine's row-locking (`FOR UPDATE`, or `BEGIN IMMEDIATE` for SQLite).
- `Notifier`: `Notify` is a no-op; `Listen` returns a channel that never fires; workers rely entirely on `NextDeadline` polling.

This keeps Postgres fully-featured while letting a minimal backend exist for tests or small deployments — proving the abstraction holds.
