defmodule BeamScope.Aggregation.SupervisorTest do
  # Not async: mutates the :beam_scope :providers application env.
  use ExUnit.Case, async: false

  alias BeamScope.Aggregation.Supervisor, as: AggSup

  @defaults [
    {BeamScope.Provider.VM, :vm},
    {BeamScope.Provider.Scheduler, :scheduler},
    {BeamScope.Provider.Processes, :processes},
    {BeamScope.Provider.ETS, :ets},
    {BeamScope.Provider.Mailbox, :mailbox}
  ]

  setup do
    original = Application.fetch_env(:beam_scope, :providers)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:beam_scope, :providers, value)
        :error -> Application.delete_env(:beam_scope, :providers)
      end
    end)

    :ok
  end

  test "defaults to the core providers when :providers is unset" do
    Application.delete_env(:beam_scope, :providers)
    assert AggSup.resolve_providers() == @defaults
  end

  test "merges configured framework providers on top of the defaults" do
    Application.put_env(:beam_scope, :providers, [{BeamScope.Provider.Phoenix, :phoenix}])

    providers = AggSup.resolve_providers()

    # every core default still runs, plus Phoenix appended
    assert providers == @defaults ++ [{BeamScope.Provider.Phoenix, :phoenix}]
  end

  test "de-duplicates a configured entry that repeats a default" do
    Application.put_env(:beam_scope, :providers, [
      {BeamScope.Provider.VM, :vm},
      {BeamScope.Provider.Phoenix, :phoenix}
    ])

    providers = AggSup.resolve_providers()

    assert providers == @defaults ++ [{BeamScope.Provider.Phoenix, :phoenix}]
    assert Enum.count(providers, &(&1 == {BeamScope.Provider.VM, :vm})) == 1
  end
end
