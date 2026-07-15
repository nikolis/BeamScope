defmodule BeamScope.Exporters.Supervisor do
  @moduledoc """
  Supervises the exporter subsystem (ADR-0007).

  Exporters are stateless leaves. The render functions
  (`BeamScope.Exporter.Prometheus`/`Dashboard`) need no process; this supervisor only runs
  BeamScope's **optional standalone HTTP endpoint** that serves them, and only when both:

    * `config :beam_scope, exporter: [port: <port>]` is set, and
    * `:bandit` (an optional dependency) is available.

  Embedded hosts that already run a web server typically skip the endpoint and mount
  `BeamScope.Exporter.Router` themselves — so this supervisor is inert by default.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  defp children do
    with opts when is_list(opts) <- Application.get_env(:beam_scope, :exporter),
         port when is_integer(port) <- Keyword.get(opts, :port),
         true <- Code.ensure_loaded?(Bandit) do
      [{Bandit, plug: BeamScope.Exporter.Router, scheme: :http, port: port}]
    else
      _ -> []
    end
  end
end
