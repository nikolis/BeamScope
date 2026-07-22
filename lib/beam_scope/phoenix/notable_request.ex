defmodule BeamScope.Phoenix.NotableRequest do
  @moduledoc """
  A single **notable request** — one thin, PII-free entry in the Phoenix domain's bounded
  `top_slow` / `recent_5xx` samples (ADR-0010).

  It is deliberately minimal: the compiled route **template** (bounded by the router, never a
  concrete path or params), the HTTP `status`, the request `latency_ms`, and a wall-clock `at`
  used only for display and recency ordering (ADR-0005). No concrete paths, params, headers, or
  stacktraces ever enter this struct — that is the bright line that keeps it an *observation*
  rather than an APM/tracing record (ADR-0001).

  These entries are a **lossy, window-scoped sample**, not an audit log: each aggregation window
  keeps at most a bounded pool and the top-N are re-ranked from it, so beyond-N and sub-window
  requests are dropped. See `BeamScope.Phoenix` and `BeamScope.Provider.Phoenix`.
  """

  @type t :: %__MODULE__{
          route: String.t(),
          status: non_neg_integer() | nil,
          latency_ms: non_neg_integer(),
          at: non_neg_integer()
        }

  defstruct route: nil, status: nil, latency_ms: 0, at: 0
end
