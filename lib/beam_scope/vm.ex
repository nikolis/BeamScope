defmodule BeamScope.VM do
  @moduledoc """
  VM-level runtime model for a single node (ADR-0004).

  A rich runtime concept, not a bag of counters: memory breakdown, aggregate run-queue
  length, per-window runtime counters (GC, reductions, IO), uptime, and OTP release.
  Produced by `BeamScope.Provider.VM` on each aggregation tick and stamped into
  `BeamScope.ClusterState`.

  The runtime counters (`gc_count`, `gc_words_reclaimed`, `gc_time_ms`, `reductions`,
  `io`) are **per-window deltas** over one aggregation interval — the emulator exposes
  them as cumulative-since-boot totals, so the provider deltas them into a rate. They are
  `nil` on the very first tick after the provider starts (no previous sample to diff), and
  `gc_time_ms` is `nil` whenever `:microstate_accounting` is disabled.
  """

  @type memory :: %{
          optional(:total) => non_neg_integer(),
          optional(:processes) => non_neg_integer(),
          optional(:binary) => non_neg_integer(),
          optional(:ets) => non_neg_integer(),
          optional(:atom) => non_neg_integer(),
          optional(:code) => non_neg_integer()
        }

  @type io :: %{
          optional(:input) => non_neg_integer() | nil,
          optional(:output) => non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          memory: memory(),
          run_queue: non_neg_integer(),
          gc_count: non_neg_integer() | nil,
          gc_words_reclaimed: non_neg_integer() | nil,
          gc_time_ms: non_neg_integer() | nil,
          reductions: non_neg_integer() | nil,
          io: io(),
          uptime_ms: non_neg_integer(),
          otp_release: String.t() | nil
        }

  defstruct memory: %{},
            run_queue: 0,
            gc_count: nil,
            gc_words_reclaimed: nil,
            gc_time_ms: nil,
            reductions: nil,
            io: %{},
            uptime_ms: 0,
            otp_release: nil
end
