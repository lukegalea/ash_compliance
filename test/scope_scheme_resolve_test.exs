# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ScopeSchemeResolveTest do
  @moduledoc """
  A five-layer SCOPE scheme (ours > pmc > property_group > contract > job)
  through the pure `Compiler.resolve/3`: origin layer, lineage order, strictly
  stronger tightening, removal that narrows below and never above, and scope
  filtering. Plus a property test that the default scheme's precedence and
  waive/replace permissions match `Compiler.Layer`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshCompliance.Compiler
  alias AshCompliance.Compiler.Layer
  alias AshCompliance.Compiler.Resolution
  alias AshCompliance.Layering
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Rule

  defmodule ScopeLayers do
    @moduledoc false
    use AshCompliance.Layering

    @edits [:add, tighten: :self_and_outer, exclude: :self_and_outer, refine: :self_and_outer]

    @impl true
    def layers do
      [
        [name: :ours, ops: [:add]],
        [name: :pmc, ops: @edits, scope_key: :pmc],
        [name: :property_group, ops: @edits, scope_key: :property_group],
        [name: :contract, ops: @edits, scope_key: :contract],
        [name: :job, ops: @edits, scope_key: :job]
      ]
    end
  end

  @gl "req.general_liability"
  @wsib "req.wsib"

  defp gl_rule do
    Rule.new(
      id: @gl,
      name: "general liability minimum",
      severity: :high,
      applicability: [Predicate.new(:has, :vendor, :awarded, true)],
      failure_conditions: [
        Predicate.new(:neg, :vendor, :gl_coverage_at_least, Layering.param(:min_amount))
      ]
    )
  end

  defp wsib_rule do
    Rule.new(
      id: @wsib,
      name: "workers' compensation clearance",
      severity: :medium,
      applicability: [Predicate.new(:has, :vendor, :awarded, true)],
      failure_conditions: [Predicate.new(:neg, :vendor, :wsib_clearance, true)]
    )
  end

  defp ours_gl(amount \\ 1_000_000) do
    %{
      layer: :ours,
      rule: gl_rule(),
      params: %{min_amount: amount},
      strength: %{min_amount: :at_least},
      source_id: "ours-gl"
    }
  end

  defp ours_wsib, do: %{layer: :ours, rule: wsib_rule(), source_id: "ours-wsib"}

  defp tighten(layer, scope, amount, source_id) do
    %{
      op: :tighten,
      layer: layer,
      rule_id: @gl,
      params: %{min_amount: amount},
      scope: scope,
      source_id: source_id
    }
  end

  defp exclude(layer, scope, rule_id, source_id) do
    %{op: :exclude, layer: layer, rule_id: rule_id, scope: scope, source_id: source_id}
  end

  defp ids(resolution), do: Enum.map(resolution.rules, & &1.id)

  defp threshold(resolution) do
    resolution.rules
    |> Enum.find(&(&1.id == @gl))
    |> Map.fetch!(:failure_conditions)
    |> hd()
    |> Map.fetch!(:value)
  end

  describe "tightening down the layers" do
    setup do
      contributions = [
        ours_gl(),
        tighten(:pmc, %{pmc: "pmc-1"}, 2_000_000, "pmc-edit"),
        tighten(:job, %{job: "job-1"}, 5_000_000, "job-edit")
      ]

      {:ok, contributions: contributions}
    end

    test "origin layer is :ours; lineage has all three edits in order; threshold is the strongest",
         %{contributions: contributions} do
      resolution = Compiler.resolve(contributions, ScopeLayers, %{pmc: "pmc-1", job: "job-1"})

      assert Resolution.ok?(resolution)

      assert [:ours] =
               for(d <- resolution.declarations, d.rule_id == @gl, do: d.layer)
               |> List.wrap()
               |> Enum.map(&declared_layer/1)
               |> Enum.uniq()

      lineage = resolution.lineage[@gl]
      assert [:add, :tighten, :tighten] == Enum.map(lineage, & &1.op)
      assert [:ours, :pmc, :job] == Enum.map(lineage, & &1.layer)
      assert ["ours-gl", "pmc-edit", "job-edit"] == Enum.map(lineage, & &1.source_id)
      assert [1_000_000, 2_000_000, 5_000_000] == Enum.map(lineage, & &1.params.min_amount)

      assert threshold(resolution) == 5_000_000
      assert Resolution.params_for(resolution, @gl) == %{min_amount: 5_000_000}
    end

    test "each context sees only the edits at or outside its own scope", %{contributions: c} do
      assert c |> Compiler.resolve(ScopeLayers, %{}) |> threshold() == 1_000_000
      assert c |> Compiler.resolve(ScopeLayers, %{pmc: "pmc-1"}) |> threshold() == 2_000_000

      assert c |> Compiler.resolve(ScopeLayers, %{pmc: "pmc-1", job: "job-1"}) |> threshold() ==
               5_000_000
    end

    test "a tighten weaker than the current value is refused, with its message", %{
      contributions: c
    } do
      weaker = tighten(:contract, %{contract: "c-1"}, 1_500_000, "contract-weaker")

      resolution =
        Compiler.resolve(c ++ [weaker], ScopeLayers, %{pmc: "pmc-1", contract: "c-1"})

      assert [refusal] = resolution.refusals
      assert refusal.reason == :not_stronger
      assert refusal.layer == :contract
      assert refusal.source_id == "contract-weaker"

      assert refusal.message ==
               "tighten of rule #{inspect(@gl)} at layer :contract refused: :min_amount " <>
                 "1500000 is not strictly stronger than 2000000 (:at_least)"

      assert Resolution.messages(resolution) == [refusal.message]
      # the refused edit is skipped; the rest still resolves
      assert threshold(resolution) == 2_000_000
    end

    test "an equal tighten is refused too (equal is never stronger)", %{contributions: c} do
      equal = tighten(:contract, %{contract: "c-1"}, 2_000_000, "contract-equal")
      resolution = Compiler.resolve(c ++ [equal], ScopeLayers, %{pmc: "pmc-1", contract: "c-1"})
      assert [%{reason: :not_stronger, source_id: "contract-equal"}] = resolution.refusals
    end
  end

  describe "removal narrows below and never above" do
    setup do
      {:ok,
       contributions: [
         ours_gl(),
         ours_wsib(),
         exclude(:property_group, %{property_group: "g-1"}, @wsib, "group-remove")
       ]}
    end

    test "a context inside the group drops the line", %{contributions: c} do
      resolution =
        Compiler.resolve(c, ScopeLayers, %{pmc: "pmc-1", property_group: ["g-1", "g-9"]})

      assert Resolution.ok?(resolution)
      assert ids(resolution) == [@gl]

      assert [%{rule_id: @wsib, layer: :property_group, source_id: "group-remove"}] =
               resolution.excluded
    end

    test "a PMC-only context keeps the line", %{contributions: c} do
      resolution = Compiler.resolve(c, ScopeLayers, %{pmc: "pmc-1"})

      assert Resolution.ok?(resolution)
      assert ids(resolution) == [@gl, @wsib]
      assert resolution.excluded == []
    end

    test "an empty context keeps it as well", %{contributions: c} do
      assert c |> Compiler.resolve(ScopeLayers, %{}) |> ids() == [@gl, @wsib]
    end
  end

  describe "scope matching" do
    test "contributions scoped to another group, contract or job are dropped, not refused" do
      contributions = [
        ours_gl(),
        ours_wsib(),
        exclude(:property_group, %{property_group: "other-group"}, @wsib, "other-group-remove"),
        tighten(:contract, %{contract: "other-contract"}, 9_000_000, "other-contract-edit"),
        tighten(:job, %{job: "other-job"}, 9_500_000, "other-job-edit")
      ]

      context = %{pmc: "pmc-1", property_group: "g-1", contract: "c-1", job: "j-1"}
      resolution = Compiler.resolve(contributions, ScopeLayers, context)

      assert Resolution.ok?(resolution)
      assert resolution.refusals == []
      assert resolution.excluded == []
      assert ids(resolution) == [@gl, @wsib]
      assert threshold(resolution) == 1_000_000
      assert [:add] == Enum.map(resolution.lineage[@gl], & &1.op)
    end

    test "a scope key missing from the context does not match" do
      contributions = [ours_gl(), tighten(:job, %{job: "j-1"}, 9_000_000, "job-edit")]
      resolution = Compiler.resolve(contributions, ScopeLayers, %{pmc: "pmc-1"})
      assert threshold(resolution) == 1_000_000
    end

    test "list-valued context overlaps a scalar scope" do
      contributions = [
        ours_gl(),
        tighten(:property_group, %{property_group: "g-2"}, 3_000_000, "g2")
      ]

      resolution = Compiler.resolve(contributions, ScopeLayers, %{property_group: ["g-1", "g-2"]})
      assert threshold(resolution) == 3_000_000
    end
  end

  describe "the default scheme matches the pre-change behavior" do
    @layers [
      :global_non_waivable,
      :global_mandatory,
      :profile_refinement,
      :tenant_strengthening,
      :approved_override,
      :tenant_supplement
    ]

    defp rule_at(id, severity),
      do:
        Rule.new(
          id: id,
          name: id,
          severity: severity,
          applicability: [Predicate.new(:has, :vendor, :awarded, true)],
          failure_conditions: [Predicate.new(:neg, :vendor, :x, true)]
        )

    defp add(layer, id, severity) do
      %{layer: layer, rule: rule_at(id, severity), source_id: "#{layer}"}
    end

    test "rank table and predicates equal the pre-change literals" do
      assert Layer.layers() == @layers
      assert Enum.map(@layers, &Layer.rank/1) == [1, 2, 3, 4, 5, 6]
      assert Enum.map(@layers, &Layer.waivable?/1) == [false, true, true, true, true, true]
      assert Enum.map(@layers, &Layer.replaceable?/1) == [false, false, false, false, false, true]
      assert_raise ArgumentError, fn -> Layer.rank(:nope) end
    end

    property "the lowest-rank declaring layer wins a same-id conflict" do
      check all(
              layers <-
                uniq_list_of(member_of(@layers), min_length: 1, max_length: 6, max_tries: 200),
              severities <- list_of(member_of([:low, :medium, :high, :critical]), length: 6)
            ) do
        contributions =
          layers |> Enum.zip(severities) |> Enum.map(fn {l, s} -> add(l, "r", s) end)

        resolution = Compiler.resolve(contributions, Layering.Default)
        assert Resolution.ok?(resolution)

        winner = Enum.min_by(layers, &Layer.rank/1)

        {_, winning_severity} =
          Enum.zip(layers, severities) |> Enum.find(fn {l, _} -> l == winner end)

        assert [%{severity: ^winning_severity}] = resolution.rules

        assert [%{layer: ^winner}] =
                 Enum.filter(resolution.lineage["r"], &(&1.op == :add)) |> Enum.take(1)
      end
    end

    property "waiver permission follows Layer.waivable?/1" do
      check all(target <- member_of(@layers)) do
        resolution =
          Compiler.resolve(
            [add(target, "r", :high), %{op: :waive, layer: :approved_override, rule_id: "r"}],
            Layering.Default
          )

        if Layer.waivable?(target) do
          assert Resolution.ok?(resolution)
          assert resolution.rules == []
        else
          assert [%{reason: :protected}] = resolution.refusals
          assert [_] = resolution.rules
        end
      end
    end

    property "replacement permission follows Layer.replaceable?/1" do
      check all(target <- member_of(@layers)) do
        replacement = rule_at("r", :low)

        resolution =
          Compiler.resolve(
            [
              add(target, "r", :high),
              %{op: :replace, layer: :approved_override, rule_id: "r", rules: [replacement]}
            ],
            Layering.Default
          )

        if Layer.replaceable?(target) do
          assert Resolution.ok?(resolution)
          assert [%{id: "r", severity: :low}] = resolution.rules
        else
          assert [%{reason: :out_of_reach}] = resolution.refusals
          assert [%{id: "r", severity: :high}] = resolution.rules
        end
      end
    end

    property "only profile_refinement may exclude, and only inner rules" do
      check all(target <- member_of(@layers), editor <- member_of(@layers)) do
        resolution =
          Compiler.resolve(
            [add(target, "r", :high), %{op: :exclude, layer: editor, rule_id: "r"}],
            Layering.Default
          )

        allowed? = editor == :profile_refinement and Layer.rank(target) > Layer.rank(editor)

        assert Resolution.ok?(resolution) == allowed?
      end
    end
  end

  defp declared_layer(%{layer: layer}), do: layer
  defp declared_layer({layer, _}), do: layer
  defp declared_layer(layer) when is_atom(layer), do: layer
end
