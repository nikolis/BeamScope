defmodule BeamScope.Aggregation.Supervisor do
  @moduledoc """
  Supervises the local aggregation subsystem (ADR-0003/0008): one `BeamScope.Aggregator`
  per enabled domain provider, plus the `:telemetry_poller` that drives gauge providers.

  The enabled domains are the core defaults (`@default_providers`) plus any framework
  providers a host adds via `config :beam_scope, :providers` (ADR-0008 "add a domain = add
  to the list"). The configured list is *merged on top of* the defaults — it adds providers
  rather than replacing the set — so enabling e.g. Phoenix never silences the core domains.
  One `BeamScope.Aggregator` runs per provider, and a single shared `:telemetry_poller` drives
  every provider's `poll/0`. Aggregators start before the poller so their telemetry
  handlers are attached before the first measurement is emitted.
  """

  use Supervisor

  @default_providers [
    {BeamScope.Provider.VM, :vm},
    {BeamScope.Provider.Scheduler, :scheduler},
    {BeamScope.Provider.Processes, :processes},
    {BeamScope.Provider.ETS, :ets},
    {BeamScope.Provider.Mailbox, :mailbox}
  ]

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval = Application.get_env(:beam_scope, :sync_interval, :timer.seconds(1))
    providers = resolve_providers()

    aggregators =
      for {provider, domain} <- providers do
        {BeamScope.Aggregator, provider: provider, domain: domain, interval: interval}
      end

    measurements =
      for {provider, _domain} <- providers,
          # Could be configureation defined modules so we need to verify their existance
          Code.ensure_loaded?(provider),
          # Again externaly defined providers so we need to make sure they implement :poll with zero params
          function_exported?(provider, :poll, 0),
          do: {provider, :poll, []}

    poller =
      {:telemetry_poller, measurements: measurements, period: interval, name: :beam_scope_poller}

    Supervisor.init(aggregators ++ [poller], strategy: :one_for_one)
  end

  @doc """
  The enabled `{provider, domain}` list: the core defaults with any configured framework
  providers (`config :beam_scope, :providers`) merged on top. Configured entries are appended
  to the defaults and de-duplicated, so adding a provider never drops a default one.
  """
  @spec resolve_providers() :: [{module(), atom()}]
  def resolve_providers do
    configured = Application.get_env(:beam_scope, :providers, [])
    Enum.uniq(@default_providers ++ configured)
  end
end
