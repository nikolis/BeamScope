defmodule BeamScope.MixProject do
  use Mix.Project

  @moduledoc false

  @version "0.0.0-dev"
  @source_url "https://github.com/nikolisgal/beam_scope"

  def project do
    [
      app: :beam_scope,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "BeamScope",
      source_url: @source_url,
      description:
        "A BEAM-native observability runtime: maintains a distributed runtime model of an " <>
          "Elixir cluster and exports it to existing observability ecosystems.",
      docs: docs()
    ]
  end

  # BeamScope is embedded into a host app (see docs/adr/0002). The host provides
  # Phoenix.PubSub and clustering; BeamScope references them by name via config.
  def application do
    [
      extra_applications: [:logger],
      mod: {BeamScope.Application, []}
    ]
  end

  # Run the whole `precommit` alias (which includes `test`) in the :test env.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # NOTE (v0.0.0-dev): dependencies are declared so the project resolves and the
  # skeleton compiles. The MVP is delivered incrementally per docs/ROADMAP.md.
  # framework-independent core only — no :phoenix, no :libcluster (host-provided).
  defp deps do
    [
      # --- runtime core (always required) ---
      {:telemetry, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},

      # --- exporters (optional; only needed to serve the HTTP endpoint, adr/0007) ---
      # The Prometheus/dashboard render functions are dependency-free; plug + bandit are
      # only required to run BeamScope's own standalone endpoint. A host can instead mount
      # BeamScope.Exporter.Router in its existing Phoenix/Plug stack.
      {:plug, "~> 1.15", optional: true},
      {:bandit, "~> 1.5", optional: true},

      # --- dev/docs ---
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # Mirrors the user's `precommit` convention from crypto_pipe/file_swarm.
  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "test"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "docs/ROADMAP.md"] ++ Path.wildcard("docs/adr/*.md"),
      groups_for_extras: [
        "Architecture Decisions": Path.wildcard("docs/adr/*.md")
      ]
    ]
  end
end
