# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.DeclaredSchemeResolveTest do
  @moduledoc """
  Smoke tests for the declared-scheme API: scoped contributions, the
  outer→inner cascade, strictly-stronger tightening and param binding. Pure:
  `resolve/3` reads nothing, so no database.
  """

  use ExUnit.Case, async: true

  alias AshCompliance.Compiler
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

  @pmc "pmc-1"
  @group "group-1"
  @job "job-1"

  defp gl_rule do
    Rule.new(
      id: "req.general_liability",
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
      id: "req.wsib",
      name: "workers' compensation clearance",
      severity: :medium,
      applicability: [Predicate.new(:has, :vendor, :awarded, true)],
      failure_conditions: [Predicate.new(:neg, :vendor, :wsib_clearance, true)]
    )
  end

  defp baseline do
    [
      %{
        layer: :ours,
        rule: gl_rule(),
        params: %{min_amount: 1_000_000},
        strength: %{min_amount: :at_least},
        source_id: "ours"
      },
      %{layer: :ours, rule: wsib_rule(), source_id: "ours"},
      %{
        op: :tighten,
        layer: :pmc,
        rule_id: "req.general_liability",
        params: %{min_amount: 2_000_000},
        scope: %{pmc: @pmc},
        source_id: "pmc-edit"
      },
      %{
        op: :exclude,
        layer: :property_group,
        rule_id: "req.wsib",
        scope: %{property_group: @group},
        source_id: "group-edit"
      },
      %{
        op: :tighten,
        layer: :job,
        rule_id: "req.general_liability",
        params: %{min_amount: 5_000_000},
        scope: %{job: @job},
        source_id: "job-edit"
      }
    ]
  end

  defp threshold(resolution) do
    rule = Enum.find(resolution.rules, &(&1.id == "req.general_liability"))
    hd(rule.failure_conditions).value
  end

  test "outer contexts never see inner edits" do
    ours = Compiler.resolve(baseline(), ScopeLayers, %{})
    assert Resolution.ok?(ours)
    assert threshold(ours) == 1_000_000
    assert "req.wsib" in Enum.map(ours.rules, & &1.id)

    pmc = Compiler.resolve(baseline(), ScopeLayers, %{pmc: @pmc})
    assert threshold(pmc) == 2_000_000
    assert "req.wsib" in Enum.map(pmc.rules, & &1.id)

    job =
      Compiler.resolve(baseline(), ScopeLayers, %{
        pmc: @pmc,
        property_group: [@group, "group-2"],
        job: @job
      })

    assert Resolution.ok?(job)
    assert threshold(job) == 5_000_000
    assert Resolution.params_for(job, "req.general_liability") == %{min_amount: 5_000_000}
    refute "req.wsib" in Enum.map(job.rules, & &1.id)
    assert [%{rule_id: "req.wsib", layer: :property_group}] = job.excluded

    assert [:add, :tighten, :tighten] ==
             Enum.map(job.lineage["req.general_liability"], & &1.op)

    assert ["ours", "pmc-edit", "job-edit"] ==
             Enum.map(job.lineage["req.general_liability"], & &1.source_id)
  end

  test "a tighten that is equal or weaker than the current value is refused" do
    contributions =
      baseline() ++
        [
          %{
            op: :tighten,
            layer: :contract,
            rule_id: "req.general_liability",
            params: %{min_amount: 2_000_000},
            scope: %{contract: "c-1"},
            source_id: "contract-edit"
          }
        ]

    resolution = Compiler.resolve(contributions, ScopeLayers, %{pmc: @pmc, contract: "c-1"})

    assert [%{reason: :not_stronger, layer: :contract, source_id: "contract-edit"}] =
             resolution.refusals

    # refusals: :all — the refused edit is skipped, the rest still resolves
    assert threshold(resolution) == 2_000_000
  end

  test "an unscoped contribution at a scoped layer is refused, whatever the context" do
    contributions =
      baseline() ++ [%{op: :exclude, layer: :job, rule_id: "req.wsib", source_id: "oops"}]

    resolution = Compiler.resolve(contributions, ScopeLayers, %{})
    assert [%{reason: :unscoped, source_id: "oops"}] = resolution.refusals
  end

  test "the bound threshold is part of the bundle hash" do
    pmc = Compiler.resolve(baseline(), ScopeLayers, %{pmc: @pmc})
    job = Compiler.resolve(baseline(), ScopeLayers, %{pmc: @pmc, job: @job})

    schema = AshRules.Ir.FactSchema.new([])
    hash = fn resolution -> AshRules.Ir.Bundle.new(resolution.rules, schema).content_hash end

    refute hash.(pmc) == hash.(job)
  end

  test "an inner layer may not re-declare an outer rule differently" do
    contributions =
      baseline() ++
        [
          %{
            layer: :job,
            rule: %{gl_rule() | severity: :low},
            params: %{min_amount: 1},
            scope: %{job: @job},
            source_id: "job-weaken"
          }
        ]

    resolution = Compiler.resolve(contributions, ScopeLayers, %{job: @job})
    assert [%{reason: :already_declared, source_id: "job-weaken"}] = resolution.refusals
  end

  test "an unbound param placeholder is refused" do
    resolution = Compiler.resolve([%{layer: :ours, rule: gl_rule()}], ScopeLayers, %{})
    assert [%{reason: :unbound_param, rule_id: "req.general_liability"}] = resolution.refusals
  end

  test "the default scheme refuses tighten everywhere" do
    rule = wsib_rule()

    resolution =
      Compiler.resolve(
        [
          %{layer: :global_mandatory, rule: rule, params: %{n: 1}, strength: %{n: :at_least}},
          %{op: :tighten, layer: :tenant_strengthening, rule_id: rule.id, params: %{n: 2}}
        ],
        Layering.Default
      )

    assert [%{reason: :op_not_allowed}] = resolution.refusals
  end
end
