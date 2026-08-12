defmodule BeamScope.Oban do
  @moduledoc """
  Oban **background-job** runtime model for a single node (ADR-0004).

  A per-interval, per-queue view of job execution on this node: how many jobs are
  currently `executing` per queue (a live gauge), and how many `completed` / `failed`
  in the last aggregation window (per-queue deltas). It also carries per-node monotonic
  `completed_total` / `failed_total` (the same category as `BeamScope.VM.uptime_ms`) so a
  Prometheus `rate()` has a counter to work on.

  This exists to answer one recurring, hard-to-answer question at a glance: *are jobs
  distributed across the cluster, or is one node doing all the work?* Oban's per-node
  concurrency limits are per node, so seeing `imports: 2` on three node rows *is* the
  proof work is spread — the node-level totals a plain VM/memory view shows cannot
  distinguish "this node hosts the job runner" from "this node hosts the operator's
  session."

  This is a **windowed queue summary, not a job store** (ADR-0001/0010). It keeps counts
  keyed by queue name — a small, bounded set — never a row per job, no job ids, no args,
  no cross-window history. Full per-job investigation is Oban's own dashboards / the jobs
  table, which live outside BeamScope. `BeamScope.Provider.Oban` populates this from
  `[:oban, :job, :start | :stop | :exception]` telemetry.
  """

  @typedoc "Per-queue counts, keyed by queue name."
  @type by_queue :: %{String.t() => non_neg_integer()}

  @type t :: %__MODULE__{
          executing: by_queue(),
          completed: by_queue(),
          failed: by_queue(),
          completed_total: non_neg_integer(),
          failed_total: non_neg_integer(),
          window_ms: non_neg_integer()
        }

  defstruct executing: %{},
            completed: %{},
            failed: %{},
            completed_total: 0,
            failed_total: 0,
            window_ms: 0
end
