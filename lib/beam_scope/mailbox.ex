defmodule BeamScope.Mailbox do
  @moduledoc """
  Mailbox runtime model for a single node (ADR-0004).

  An aggregate, distributional view of process mailboxes — total and maximum queued
  messages, a count of backlogged processes (mailbox at or above the configured
  threshold), and a fixed 5-bucket histogram of mailbox lengths.

  This is distinct from `BeamScope.ProcessSummary`, which owns the per-process top-N
  (largest mailboxes/memory). Mailbox owns the aggregate/distributional view of the
  whole process population, so the two models never overlap.
  """

  @typedoc "Fixed 5-bucket histogram of mailbox lengths, keyed by bucket label."
  @type distribution :: %{String.t() => non_neg_integer()}

  @type t :: %__MODULE__{
          total_queued: non_neg_integer(),
          max_queued: non_neg_integer(),
          backlogged: non_neg_integer(),
          backlog_threshold: non_neg_integer(),
          distribution: distribution()
        }

  defstruct total_queued: 0,
            max_queued: 0,
            backlogged: 0,
            backlog_threshold: 0,
            distribution: %{"0" => 0, "1-9" => 0, "10-99" => 0, "100-999" => 0, "1000+" => 0}
end
