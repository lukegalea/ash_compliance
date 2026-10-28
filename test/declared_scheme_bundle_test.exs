# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.DeclaredSchemeBundleTest do
  @moduledoc """
  Persisting what a declared scheme compiles: a `PolicyBundle` compiled
  through the `compile` action under a host scheme and source records the
  scheme's name and the source's lineage, and a `RuleSetRevision` may sit at
  a layer of its own scheme. Neither ever reaches the default path: the
  active reads and the default gather see default-scheme rows only.
  """

  use AshCompliance.DataCase, async: true

  alias AshCompliance.Compiler
  alias AshCompliance.Domain
  alias AshCompliance.Layering
  alias AshCompliance.Test.RuleSets
  alias AshCompliance.Test.Support
  alias AshRules.Ir.{Fact, FactSchema, Predicate, Rule}

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defmodule TwoLayers do
    @moduledoc false
    use AshCompliance.Layering

    @impl true
    def layers do
      [
        [name: :ours, ops: [:add]],
        [name: :pmc, ops: [:add, tighten: :self_and_outer], scope_key: :pmc]
      ]
    end
  end

  defmodule Source do
    @moduledoc false
    @behaviour AshCompliance.Compiler.ContributionSource

    @impl true
    def gather(opts) do
      pmc = get_in(opts, [:context, :pmc])

      rule =
        Rule.new(
          id: "req.gl",
          name: "general liability minimum",
          severity: :high,
          applicability: [Predicate.new(:has, :vendor, :awarded, true)],
          failure_conditions: [
            Predicate.new(:neg, :vendor, :gl_at_least, Layering.param(:min_amount))
          ],
          outcome: AshRules.Ir.OutcomeDeclaration.new(:noncompliant, "req.gl")
        )

      {:ok,
       %{
         contributions: [
           %{
             layer: :ours,
             rule: rule,
             params: %{min_amount: 2_000_000},
             strength: %{min_amount: :at_least},
             source_id: "ours-gl"
           },
           %{
             layer: :pmc,
             op: :tighten,
             rule_id: "req.gl",
             params: %{min_amount: 3_000_000},
             scope: %{pmc: pmc},
             source_id: "pmc-gl"
           }
         ],
         fact_schema:
           FactSchema.new([Fact.new(:awarded, :boolean), Fact.new(:gl_at_least, :number)])
       }}
    end

    @impl true
    def lineage(_gathered, resolution) do
      for {rule_id, steps} <- resolution.lineage, step <- steps do
        %{rule_id: rule_id, layer: step.layer, op: step.op, source_id: step.source_id}
      end
    end
  end

  defmodule NoLineage do
    @moduledoc false
    @behaviour AshCompliance.Compiler.ContributionSource
    @impl true
    def gather(opts), do: AshCompliance.DeclaredSchemeBundleTest.Source.gather(opts)
  end

  # Stored lineage comes back from jsonb with string keys and values.
  defp stored(entries, keys) do
    Enum.map(entries, fn entry ->
      Map.new(keys, fn key ->
        value = Map.get(entry, key, Map.get(entry, to_string(key)))
        {key, if(is_atom(value) and not is_nil(value), do: to_string(value), else: value)}
      end)
    end)
  end

  defp compile_declared(org, pmc) do
    Domain.compile_policy_bundle!(
      %{
        organization_id: org,
        label: "requirements",
        scheme: TwoLayers,
        source: Source,
        context: %{pmc: pmc}
      },
      authorize?: false
    )
  end

  describe "PolicyBundle under a declared scheme" do
    test "records the scheme and the source's lineage, and binds the tightened param" do
      org = Ecto.UUID.generate()
      pmc = Ecto.UUID.generate()
      bundle = compile_declared(org, pmc)

      assert bundle.scheme == inspect(TwoLayers)

      assert {:ok, expected, _lineage} =
               Compiler.compile(scheme: TwoLayers, source: Source, context: %{pmc: pmc})

      assert bundle.content_hash == expected.content_hash
      assert bundle.contributions |> stored([:layer]) |> Enum.map(& &1.layer) == ["ours", "pmc"]

      {:ok, decoded} = AshRules.Ir.decode(bundle.rules_json)
      [rule] = decoded.rules
      assert [%{value: 3_000_000}] = rule.failure_conditions
    end

    test "a source with no lineage of its own stores the resolution's steps as a list" do
      bundle =
        Domain.compile_policy_bundle!(
          %{
            organization_id: Ecto.UUID.generate(),
            scheme: TwoLayers,
            source: NoLineage,
            context: %{pmc: "p"}
          },
          authorize?: false
        )

      assert [%{rule_id: "req.gl", layer: "ours"}, %{rule_id: "req.gl", layer: "pmc"}] =
               stored(bundle.contributions, [:rule_id, :layer])
    end

    test "an active declared-scheme bundle never answers the default active read" do
      org = Ecto.UUID.generate()
      bundle = Domain.activate_policy_bundle!(compile_declared(org, "p"), authorize?: false)

      assert Domain.active_policy_bundle!(org, authorize?: false) == nil
      assert Domain.latest_policy_bundle!(org, authorize?: false) == nil

      assert Domain.active_policy_bundle!(org, %{scheme: inspect(TwoLayers)}, authorize?: false).id ==
               bundle.id
    end

    test "the default compile records no scheme and reads only default bundles" do
      org = Ecto.UUID.generate()
      Domain.activate_policy_bundle!(compile_declared(org, "p"), authorize?: false)

      default = Domain.compile_policy_bundle!(%{organization_id: org}, authorize?: false)
      default = Domain.activate_policy_bundle!(default, authorize?: false)

      assert default.scheme == nil
      assert Domain.active_policy_bundle!(org, authorize?: false).id == default.id
    end

    test "a scheme argument that is not a layering scheme is refused" do
      assert {:error, _} =
               Domain.compile_policy_bundle(
                 %{organization_id: Ecto.UUID.generate(), scheme: Source},
                 authorize?: false
               )
    end
  end

  describe "RuleSetRevision under a declared scheme" do
    test "sits at a layer of its scheme" do
      revision =
        Support.rule_set_revision(layer: :pmc, scheme: inspect(TwoLayers), as_of: @now)

      assert revision.layer == :pmc
      assert revision.scheme == inspect(TwoLayers)
    end

    test "a layer outside its scheme is refused, and so is a default rank" do
      assert_raise Ash.Error.Invalid, ~r/must be one of ours, pmc/, fn ->
        Support.rule_set_revision(layer: :global_mandatory, scheme: inspect(TwoLayers))
      end
    end

    test "with no scheme the layer is one of the six default ranks, as always" do
      assert_raise Ash.Error.Invalid, ~r/must be one of global_non_waivable/, fn ->
        Support.rule_set_revision(layer: :pmc)
      end
    end

    test "a scheme that is not a loaded layering module is refused" do
      assert_raise Ash.Error.Invalid, ~r/not a loaded AshCompliance.Layering module/, fn ->
        Support.rule_set_revision(layer: :ours, scheme: "No.Such.SchemeAnywhere")
      end
    end

    test "the default gather never sees an active declared-scheme revision" do
      org = Ecto.UUID.generate()
      before = Compiler.compile(organization_id: org, now: @now)

      Support.rule_set_revision(
        organization_id: org,
        layer: :ours,
        scheme: inspect(TwoLayers),
        rules_json: Support.bundle_json(RuleSets.GlobalBaseline),
        as_of: @now
      )
      |> Domain.validate_rule_set_revision!(authorize?: false, as_of: @now)
      |> Domain.approve_rule_set_revision!(authorize?: false, as_of: @now)
      |> Domain.activate_rule_set_revision!(authorize?: false, as_of: @now)

      assert Compiler.compile(organization_id: org, now: @now) == before
      assert Domain.active_rule_set_revisions!(org, authorize?: false, as_of: @now) == []

      assert [%{layer: :ours}] =
               Domain.active_rule_set_revisions!(org, %{scheme: inspect(TwoLayers)},
                 authorize?: false,
                 as_of: @now
               )
    end
  end
end
