# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.DefaultSchemeEquivalenceTest do
  @moduledoc """
  The declared-scheme compiler, on its default path (DatabaseSource +
  Layering.Default), is bit-for-bit the compiler it replaced: same bundle
  struct (rules, revision string, combining, content hash), same lineage,
  same refusal messages. `AshCompliance.Test.LegacyCompiler` is a frozen copy
  of the pre-change compiler and serves as the oracle.
  """

  use AshCompliance.DataCase, async: true

  alias AshCompliance.Compiler
  alias AshCompliance.Compiler.Layer
  alias AshCompliance.Layering
  alias AshCompliance.Test.LegacyCompiler
  alias AshCompliance.Test.RuleSets
  alias AshCompliance.Test.Support

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  describe "Layer answers from Layering.Default exactly as the fixed table did" do
    test "order, ranks and permissions" do
      assert Layer.layers() == [
               :global_non_waivable,
               :global_mandatory,
               :profile_refinement,
               :tenant_strengthening,
               :approved_override,
               :tenant_supplement
             ]

      assert Layer.revision_layers() == Layer.layers() -- [:approved_override]
      assert Enum.map(Layer.layers(), &Layer.rank/1) == [1, 2, 3, 4, 5, 6]
      assert Layer.outranks?(:global_mandatory, :tenant_supplement)
      refute Layer.outranks?(:tenant_supplement, :global_mandatory)

      assert Enum.map(Layer.layers(), &Layer.replaceable?/1) ==
               [false, false, false, false, false, true]

      assert Enum.map(Layer.layers(), &Layer.waivable?/1) ==
               [false, true, true, true, true, true]

      assert Layering.precedence(Layering.Default) == %{
               declarations: :outer_wins,
               edits: :against_declarations,
               refusals: :first
             }
    end
  end

  describe "compile/1 equals the legacy compiler" do
    test "an organization with nothing active" do
      org = Ecto.UUID.generate()
      assert {:ok, _bundle, []} = same(org)
    end

    test "every layer contributing, with a same-id conflict" do
      org = Ecto.UUID.generate()
      activate(org, :global_non_waivable, RuleSets.GlobalNonWaivable)
      activate(org, :global_mandatory, RuleSets.GlobalBaseline)
      activate(org, :tenant_strengthening, RuleSets.TenantStrengthening)
      activate(org, :tenant_supplement, RuleSets.TenantSupplement)

      # Re-declares the mandatory rule one layer down: the outer one wins.
      create_and_activate(
        org,
        :tenant_strengthening,
        rules_json([%{mandatory_rule() | severity: :critical}]),
        combining: :permit_overrides
      )

      assert {:ok, bundle, lineage} = same(org)
      assert length(bundle.rules) > 3
      assert Enum.find(bundle.rules, &(&1.id == "kyc.valid_required")).severity == :medium
      assert length(lineage) == 5
    end

    test "waivers in force and expired, plus replacements and profile edits" do
      org = Ecto.UUID.generate()
      activate(org, :global_mandatory, RuleSets.GlobalBaseline)
      activate(org, :tenant_strengthening, RuleSets.TenantStrengthening)
      activate(org, :tenant_supplement, RuleSets.TenantSupplement)

      waive(org, "kyc.review_required", expires_at: hours_after(@now, 24))

      waive(org, "acct.balance_frozen",
        starts_at: hours_after(@now, -48),
        expires_at: hours_after(@now, -1)
      )

      replacement = %{
        mandatory_rule()
        | id: "kyc.welcome_review",
          severity: :critical,
          message: "replacement welcome review"
      }

      extra = %{mandatory_rule() | id: "kyc.extra_from_replacement", severity: :low}
      replace(org, "kyc.welcome_review", rules_json([replacement, extra]))

      profile_with(org, [
        %{"op" => "refine", "target" => "acct.balance_frozen", "severity" => "critical"},
        %{"op" => "refine", "target" => "acct.balance_frozen", "message" => "refined twice"},
        %{"op" => "refine", "target" => "kyc.welcome_review", "severity" => "high"},
        %{"op" => "include", "target" => "kyc.valid_required"},
        %{"op" => "supplement", "target" => "kyc.valid_required", "text" => "note"}
      ])

      assert {:ok, bundle, lineage} = same(org)
      ids = Enum.map(bundle.rules, & &1.id)
      refute "kyc.review_required" in ids
      assert "acct.balance_frozen" in ids
      assert "kyc.extra_from_replacement" in ids
      assert Enum.find(bundle.rules, &(&1.id == "kyc.welcome_review")).severity == :high
      assert Enum.any?(lineage, &(&1.effect == :replaced))
      assert Enum.any?(lineage, &(&1.effect == :excluded_by_waiver))
    end

    test "a profile exclude of a tenant rule" do
      org = Ecto.UUID.generate()
      activate(org, :global_mandatory, RuleSets.GlobalBaseline)
      activate(org, :tenant_strengthening, RuleSets.TenantStrengthening)
      profile_with(org, [%{"op" => "exclude", "target" => "acct.balance_frozen"}])

      assert {:ok, bundle, _lineage} = same(org)
      refute "acct.balance_frozen" in Enum.map(bundle.rules, & &1.id)
    end

    test "combining comes from the highest-precedence winner" do
      org = Ecto.UUID.generate()

      create_and_activate(
        org,
        :tenant_strengthening,
        Support.bundle_json(RuleSets.TenantStrengthening),
        combining: :permit_overrides
      )

      assert {:ok, %{combining: :permit_overrides}, _} = same(org)
    end
  end

  describe "refusals equal the legacy compiler's" do
    test "waiver of a non-waivable rule" do
      org = Ecto.UUID.generate()
      activate(org, :global_non_waivable, RuleSets.GlobalNonWaivable)
      waive(org, "kyc.jurisdiction_required", expires_at: hours_after(@now, 24))
      assert {:error, [_]} = same(org)
    end

    test "waiver and replacement of undeclared rules" do
      org = Ecto.UUID.generate()
      waive(org, "kyc.nope", expires_at: hours_after(@now, 24))
      assert {:error, [_]} = same(org)

      org = Ecto.UUID.generate()
      replace(org, "kyc.nope", rules_json([mandatory_rule()]))
      assert {:error, [_]} = same(org)
    end

    test "replacement of a mandatory rule, and an undecodable replacement" do
      org = Ecto.UUID.generate()
      activate(org, :global_mandatory, RuleSets.GlobalBaseline)
      replace(org, "kyc.valid_required", rules_json([%{mandatory_rule() | severity: :low}]))
      assert {:error, [message]} = same(org)
      assert message =~ "outranks approved overrides"

      org = Ecto.UUID.generate()
      activate(org, :tenant_supplement, RuleSets.TenantSupplement)
      replace(org, "kyc.welcome_review", "{not json")
      assert {:error, [message]} = same(org)
      assert message =~ "does not decode"
    end

    test "profile parameterize, exclude and refine overreach" do
      for op <- [
            %{"op" => "parameterize", "target" => "kyc.valid_required"},
            %{"op" => "exclude", "target" => "kyc.valid_required"},
            %{"op" => "refine", "target" => "kyc.valid_required", "severity" => "low"},
            %{"op" => "exclude", "target" => "kyc.nope"},
            %{"op" => "refine", "target" => "kyc.nope", "severity" => "low"}
          ] do
        org = Ecto.UUID.generate()
        activate(org, :global_mandatory, RuleSets.GlobalBaseline)
        profile_with(org, [op])
        assert {:error, [_]} = same(org)
      end
    end

    test "with several refusals, the first one the legacy compiler hit is reported" do
      org = Ecto.UUID.generate()
      activate(org, :global_non_waivable, RuleSets.GlobalNonWaivable)
      activate(org, :global_mandatory, RuleSets.GlobalBaseline)
      waive(org, "kyc.jurisdiction_required", expires_at: hours_after(@now, 24))
      profile_with(org, [%{"op" => "exclude", "target" => "kyc.valid_required"}])

      assert {:error, [message]} = same(org)
      assert message =~ "non-waivable"
    end
  end

  # --- helpers ------------------------------------------------------------------

  defp same(org) do
    new = Compiler.compile(organization_id: org, now: @now)
    legacy = LegacyCompiler.compile(organization_id: org, now: @now)
    assert new == legacy

    case new do
      {:ok, bundle, _} ->
        {:ok, legacy_bundle, _} = legacy
        assert bundle.content_hash == legacy_bundle.content_hash
        assert bundle.revision == legacy_bundle.revision

      _ ->
        :ok
    end

    new
  end

  defp hours_after(base, hours), do: DateTime.add(base, hours * 3600, :second)

  defp mandatory_rule do
    RuleSets.GlobalBaseline.__bundle__().rules |> Enum.find(&(&1.id == "kyc.valid_required"))
  end

  defp rules_json(rules) do
    schema = RuleSets.GlobalBaseline.__bundle__().fact_schema
    AshRules.Ir.encode!(AshRules.Ir.Bundle.new(rules, schema))
  end

  defp activate(org, layer, module),
    do: create_and_activate(org, layer, Support.bundle_json(module), [])

  defp create_and_activate(org, layer, json, opts) do
    Support.rule_set_revision(
      organization_id: org,
      name: "rules-" <> Support.unique(),
      layer: layer,
      combining: Keyword.get(opts, :combining, :deny_overrides),
      rules_json: json,
      content_hash: Support.unique(),
      as_of: @now
    )
    |> AshCompliance.Domain.validate_rule_set_revision!(authorize?: false, as_of: @now)
    |> AshCompliance.Domain.approve_rule_set_revision!(authorize?: false, as_of: @now)
    |> AshCompliance.Domain.activate_rule_set_revision!(authorize?: false, as_of: @now)
  end

  defp waive(org, rule_id, opts) do
    AshCompliance.Domain.create_policy_override!(
      %{
        organization_id: org,
        kind: :waive,
        rule_id: rule_id,
        reason: "documented operational exception",
        approver: "security-officer",
        approved_at: @now,
        starts_at: Keyword.get(opts, :starts_at, @now),
        expires_at: opts[:expires_at],
        compensating_controls: ["manual-review"]
      },
      authorize?: false
    )
  end

  defp replace(org, rule_id, json) do
    AshCompliance.Domain.create_policy_override!(
      %{
        organization_id: org,
        kind: :replace,
        rule_id: rule_id,
        reason: "equivalent local control",
        approver: "security-officer",
        approved_at: @now,
        replacement_rules_json: json,
        compensating_controls: []
      },
      as_of: @now,
      authorize?: false
    )
  end

  defp profile_with(org, operations) do
    {:ok, profile} =
      AshCompliance.Domain.create_profile(
        %{organization_id: org, name: "profile-" <> Support.unique()},
        authorize?: false
      )

    {:ok, revision} =
      AshCompliance.Domain.create_profile_revision(
        %{
          profile_id: profile.id,
          version: "1",
          operations: operations,
          content_hash: Support.unique()
        },
        authorize?: false
      )

    AshCompliance.Domain.create_tenant_policy_set!(
      %{organization_id: org, name: "policy-set", profile_revision_ids: [revision.id]},
      authorize?: false
    )
  end
end
