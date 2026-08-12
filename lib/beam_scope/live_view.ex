defmodule BeamScope.LiveView do
  @moduledoc """
  Phoenix **LiveView** runtime model for a single node (ADR-0004).

  A per-interval view of the LiveView surface on this node: how many `mounts` and
  `handle_events` occurred in the last aggregation window, the average `handle_event`
  latency and a fixed-bucket histogram, and `connected_sockets` — the number of live
  LiveView sessions this node is *currently* holding.

  `connected_sockets` is the piece a plain VM/memory view is missing: LiveView load
  originates in LiveView processes, so a node that looks like an outlier on memory or
  mailbox is very often just the one holding N live sessions. The socket count is the
  natural denominator for interpreting those outliers, and — like `BeamScope.VM.uptime_ms`
  — it is a per-node *latest observation* gauge, not replicated data (ADR-0001).

  This is a **windowed summary, not an event/session store** (ADR-0001/0010): counts and a
  bounded histogram, never a row per event or per socket. It owns only the LiveView surface;
  the Phoenix HTTP surface (`BeamScope.Phoenix`) and Presence are separate models, so they
  never overlap. `BeamScope.Provider.LiveView` populates this from
  `[:phoenix, :live_view, :mount | :handle_event, ...]` telemetry plus pid monitoring for the
  live socket count.
  """

  @typedoc "Fixed latency histogram (ms buckets), keyed by bucket label."
  @type latency_distribution :: %{String.t() => non_neg_integer()}

  @type t :: %__MODULE__{
          mounts: non_neg_integer(),
          handle_events: non_neg_integer(),
          avg_latency_ms: float() | nil,
          latency_distribution: latency_distribution(),
          connected_sockets: non_neg_integer(),
          window_ms: non_neg_integer()
        }

  defstruct mounts: 0,
            handle_events: 0,
            avg_latency_ms: nil,
            latency_distribution: %{
              "0-10" => 0,
              "10-50" => 0,
              "50-200" => 0,
              "200-1000" => 0,
              "1000+" => 0
            },
            connected_sockets: 0,
            window_ms: 0
end
