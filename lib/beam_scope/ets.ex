defmodule BeamScope.ETS do
  @moduledoc """
  ETS runtime model for a single node (ADR-0004).

  Total table count and memory, plus the top-N largest tables by memory. Memory is
  reported in bytes (ETS reports words; converted via the emulator word size).
  """

  @type table :: %{name: atom(), memory_bytes: non_neg_integer(), size: non_neg_integer()}

  @type t :: %__MODULE__{
          table_count: non_neg_integer(),
          memory_bytes: non_neg_integer(),
          largest: [table()]
        }

  defstruct table_count: 0, memory_bytes: 0, largest: []
end
