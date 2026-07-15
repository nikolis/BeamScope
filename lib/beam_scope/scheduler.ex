defmodule BeamScope.Scheduler do
  @moduledoc """
  Scheduler runtime model for a single node (ADR-0004).

  `utilization` is the overall fraction of scheduler time spent doing work (0.0–1.0),
  and `per_scheduler` breaks that down per normal scheduler. Utilization is a delta
  between two `:scheduler_wall_time` samples, so it is `nil` on the very first tick
  after the provider starts.
  """

  @type utilization :: float() | nil

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          online: non_neg_integer(),
          dirty_cpu: non_neg_integer(),
          dirty_io: non_neg_integer(),
          utilization: utilization(),
          per_scheduler: [%{id: pos_integer(), utilization: float()}]
        }

  defstruct count: 0,
            online: 0,
            dirty_cpu: 0,
            dirty_io: 0,
            utilization: nil,
            per_scheduler: []
end
