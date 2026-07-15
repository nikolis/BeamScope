defmodule BeamScope.Aggregation.Supervisor do
  @moduledoc """
  Supervises the local aggregation subsystem (ADR-0003/0008): one `BeamScope.Aggregator`
  per enabled domain provider, plus the `:telemetry_poller` that drives gauge providers.

  The enabled domains are a config list of `{provider, domain}` (ADR-0008 "add a domain =
  add to the list"), overridable via `config :beam_scope, :providers`. One
  `BeamScope.Aggregator` runs per provider, and a single shared `:telemetry_poller` drives
  every provider's `poll/0`. Aggregators start before the poller so their telemetry
  handlers are attached before the first measurement is emitted.
  """

  use Supervisor

  @default_providers [
    {BeamScope.Provider.VM, :vm},
    {BeamScope.Provider.Scheduler, :scheduler},
    {BeamScope.Provider.Processes, :processes},
    {BeamScope.Provider.ETS, :ets}
  ]

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval = Application.get_env(:beam_scope, :sync_interval, :timer.seconds(1))
    providers = Application.get_env(:beam_scope, :providers, @default_providers)

    aggregators =
      for {provider, domain} <- providers do
        {BeamScope.Aggregator, provider: provider, domain: domain, interval: interval}
      end

    measurements =
      for {provider, _domain} <- providers,
          Code.ensure_loaded?(provider),
          function_exported?(provider, :poll, 0),
          do: {provider, :poll, []}

    poller =
      {:telemetry_poller, measurements: measurements, period: interval, name: :beam_scope_poller}

    Supervisor.init(aggregators ++ [poller], strategy: :one_for_one)
  end
end
