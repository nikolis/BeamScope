defmodule BeamScope.ProcessSummary do
  @moduledoc """
  Process-population runtime model for a single node (ADR-0004).

  A bounded summary — total `count` against the `limit`, plus top-N processes by
  mailbox length and by memory. `pid` is stored as a string: a remote node's pid is
  display-only and must not be treated as a live local reference.
  """

  @type entry :: %{pid: String.t(), name: atom() | nil, value: non_neg_integer()}

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          limit: non_neg_integer(),
          top_mailboxes: [entry()],
          top_memory: [entry()]
        }

  defstruct count: 0, limit: 0, top_mailboxes: [], top_memory: []
end
