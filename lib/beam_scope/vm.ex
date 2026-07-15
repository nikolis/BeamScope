defmodule BeamScope.VM do
  @moduledoc """
  VM-level runtime model for a single node (ADR-0004).

  A rich runtime concept, not a bag of counters: memory breakdown, aggregate run-queue
  length, uptime, and OTP release. Produced by `BeamScope.Provider.VM` on each
  aggregation tick and stamped into `BeamScope.ClusterState`.
  """

  @type memory :: %{
          optional(:total) => non_neg_integer(),
          optional(:processes) => non_neg_integer(),
          optional(:binary) => non_neg_integer(),
          optional(:ets) => non_neg_integer(),
          optional(:atom) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          memory: memory(),
          run_queue: non_neg_integer(),
          uptime_ms: non_neg_integer(),
          otp_release: String.t() | nil
        }

  defstruct memory: %{}, run_queue: 0, uptime_ms: 0, otp_release: nil
end
