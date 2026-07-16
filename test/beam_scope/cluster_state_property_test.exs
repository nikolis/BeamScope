defmodule BeamScope.ClusterStatePropertyTest do
  @moduledoc """
  Convergence properties for `BeamScope.ClusterState.merge/1` (ADR-0005/0006).

  Merge must be a per-node last-observation-wins by the `{incarnation, version}` logical
  clock, which makes it **commutative and idempotent per node** — the property that makes
  AP snapshot gossip safe regardless of delivery order or duplication.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias BeamScope.{ClusterNode, ClusterState}

  # Small domains so nodes and clocks collide often, exercising the LWW logic.
  defp snapshot do
    gen all(
          name <- member_of([:a@h, :b@h, :c@h]),
          incarnation <- integer(1..3),
          version <- integer(1..5)
        ) do
      %ClusterNode{
        node: name,
        incarnation: incarnation,
        version: version,
        observed_at: 0,
        entities: %{}
      }
    end
  end

  defp reset, do: ClusterState.reset()

  # The clock each node should converge to: the max {incarnation, version} seen for it.
  defp expected_clocks(snapshots) do
    Enum.reduce(snapshots, %{}, fn s, acc ->
      Map.update(acc, s.node, {s.incarnation, s.version}, &max(&1, {s.incarnation, s.version}))
    end)
  end

  defp actual_clocks do
    ClusterState.nodes() |> Map.new(&{&1.node, {&1.incarnation, &1.version}})
  end

  property "merge converges to the max clock per node, independent of order" do
    check all(snapshots <- list_of(snapshot(), max_length: 20)) do
      expected = expected_clocks(snapshots)

      reset()
      Enum.each(snapshots, &ClusterState.merge/1)
      assert actual_clocks() == expected

      # A different delivery order must reach the same converged state.
      reset()
      Enum.each(Enum.shuffle(snapshots), &ClusterState.merge/1)
      assert actual_clocks() == expected
    end
  end

  property "merge is idempotent — replaying snapshots changes nothing" do
    check all(snapshots <- list_of(snapshot(), max_length: 20)) do
      reset()
      Enum.each(snapshots, &ClusterState.merge/1)
      converged = actual_clocks()

      # Replaying every snapshot (duplicates + a shuffle) leaves the state unchanged.
      Enum.each(Enum.shuffle(snapshots), &ClusterState.merge/1)
      assert actual_clocks() == converged
    end
  end

  property "merge never regresses a node's clock" do
    check all(snapshots <- list_of(snapshot(), min_length: 1, max_length: 20)) do
      reset()

      Enum.reduce(snapshots, %{}, fn s, seen ->
        ClusterState.merge(s)
        stored = ClusterState.get(s.node)
        prev = Map.get(seen, s.node, {0, 0})
        # the stored clock is monotonic non-decreasing and at least this snapshot's clock
        assert {stored.incarnation, stored.version} >= prev
        assert {stored.incarnation, stored.version} >= {s.incarnation, s.version}
        Map.update(seen, s.node, {s.incarnation, s.version}, &max(&1, {s.incarnation, s.version}))
      end)
    end
  end
end
