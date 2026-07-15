defmodule BeamScope.DomainProvider do
  @moduledoc """
  Behaviour for a **domain provider** — a plugin that observes one runtime domain
  and contributes entities to the runtime object model (see `docs/adr/0008`).

  A provider declares the telemetry/poller sources it consumes, folds raw events
  into a local accumulator (cheap, in ETS/counters), and periodically emits a
  compact list of runtime-model structs.

  MVP providers (`docs/ROADMAP.md`, Inc 1 & 3) are framework-independent: VM,
  Scheduler, Process, ETS — built on `:telemetry_poller` and runtime introspection.
  Future providers (Phoenix, LiveView, Presence, Oban, Broadway, custom metrics)
  plug in with **zero core change** — this is the pivot from "observability library
  with integrations" to "runtime platform with pluggable domain providers".

  > Not yet implemented — delivered incrementally in `docs/ROADMAP.md`.
  """

  @typedoc "A telemetry event name or a `{:poller, mfa}` measurement source."
  @type source :: [atom()] | {:poller, mfa()}

  @doc """
  Optional one-time setup, run by the aggregator before handlers are attached.

  Use it for global side effects a provider needs, e.g. enabling a VM flag such as
  `:scheduler_wall_time`. Providers that need no setup simply omit it.
  """
  @callback setup() :: :ok

  @doc "The telemetry/poller sources this provider consumes."
  @callback sources() :: [source()]

  @doc "Fold a single raw telemetry event into the provider's accumulator."
  @callback aggregate(
              event :: [atom()],
              measurements :: map(),
              metadata :: map(),
              acc :: term()
            ) :: term()

  @doc "Produce the current runtime-model entities from the accumulator."
  @callback snapshot(acc :: term()) :: [struct()]

  @optional_callbacks setup: 0
end
