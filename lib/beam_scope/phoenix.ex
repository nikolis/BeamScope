defmodule BeamScope.Phoenix do
  @moduledoc """
  Phoenix **HTTP request** runtime model for a single node (ADR-0004).

  A per-interval, windowed view of the endpoint's request surface — the request and error
  counts observed in the last aggregation window (default ~1s), the average request latency
  and a fixed-bucket latency histogram, and the distribution of responses by status class.
  It also carries two **per-node monotonic** totals (`requests_total`/`errors_total`), the
  same category of reading as `BeamScope.VM.uptime_ms` — a per-node latest observation, not
  replicated data (ADR-0001) — so a Prometheus `rate()` has a monotonic counter to work on.

  This is the first framework provider (ADR-0008) and owns only the **HTTP** surface.
  Channels/sockets, LiveView, and Presence are separate future domains (ADR-0004) with
  their own structs, so the models never overlap. `BeamScope.Provider.Phoenix` populates
  this from `[:phoenix, :endpoint, :stop | :exception]` telemetry.

  It also carries two bounded **notable-request** samples (ADR-0010) — `top_slow` (the
  slowest requests this window) and `recent_5xx` (the most recent 5xx/exception requests) —
  each a fixed-size list of `BeamScope.Phoenix.NotableRequest`. These are a *signpost*
  ("which route/node is hot?"), not a request store: they are a **lossy, window-scoped
  sample**, never an audit log or a complete list of errors. Beyond-N and sub-window requests
  are dropped, and a restart empties them. Full per-request investigation is APM/tracing and
  lives outside BeamScope (compose via `opentelemetry_phoenix`).
  """

  alias BeamScope.Phoenix.NotableRequest

  @typedoc "Fixed latency histogram (ms buckets), keyed by bucket label."
  @type latency_distribution :: %{String.t() => non_neg_integer()}

  @typedoc "Response counts by HTTP status class, keyed by class label."
  @type status_classes :: %{String.t() => non_neg_integer()}

  @type t :: %__MODULE__{
          requests: non_neg_integer(),
          errors: non_neg_integer(),
          error_rate: float(),
          avg_latency_ms: float() | nil,
          latency_distribution: latency_distribution(),
          status_classes: status_classes(),
          window_ms: non_neg_integer(),
          requests_total: non_neg_integer(),
          errors_total: non_neg_integer(),
          top_slow: [NotableRequest.t()],
          recent_5xx: [NotableRequest.t()]
        }

  defstruct requests: 0,
            errors: 0,
            error_rate: 0.0,
            avg_latency_ms: nil,
            latency_distribution: %{
              "0-10" => 0,
              "10-50" => 0,
              "50-200" => 0,
              "200-1000" => 0,
              "1000+" => 0
            },
            status_classes: %{"2xx" => 0, "3xx" => 0, "4xx" => 0, "5xx" => 0},
            window_ms: 0,
            requests_total: 0,
            errors_total: 0,
            top_slow: [],
            recent_5xx: []
end
