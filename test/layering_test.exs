# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.LayeringTest do
  @moduledoc """
  Compiler precedence golden cases: the fixed layering, override permissions,
  waiver expiry, and combining propagation.
  """

  use AshCompliance.DataCase, async: true

  alias AshCompliance.Compiler
  alias AshCompliance.Test.Support

  @org Ecto.UUID.generate()
  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  describe "fixed precedence" do
    test "rules from different layers all apply when they do not conflict" do
      baseline = activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)

      strengthening =
        activate(:tenant_strengthening, AshCompliance.Test.RuleSets.TenantStrengthening)

      {:ok, bundle, lineage} =
        Compiler.compile(organization_id: @org, now: @now)

      rule_ids = Enum.map(bundle.rules, & &1.id)

      assert "kyc.valid_required" in rule_ids
      assert "acct.balance_frozen" in rule_ids

      assert [baseline.id, strengthening.id]
             |> Enum.all?(fn id ->
               Enum.any?(lineage, &(&1.revision_id == id and &1.effect == :included))
             end)
    end

    test "a higher layer wins on the same rule id" do
      # The strengthening set re-declares the mandatory rule with a harsher
      # severity: same id, lower rank wins — the mandatory baseline stays.
      override_rule = %{mandatory_rule() | severity: :critical}
      json = rules_json([override_rule])

      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)
      create_revision(:tenant_strengthening, "strengthener", json)

      {:ok, bundle, _lineage} = Compiler.compile(organization_id: @org, now: @now)

      rule = Enum.find(bundle.rules, &(&1.id == "kyc.valid_required"))
      assert rule.severity == :medium
    end
  end

  describe "waivers" do
    test "a valid waiver excludes its rule from the effective bundle" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)

      waive("kyc.review_required", expires_at: hours_after(@now, 24))

      {:ok, bundle, lineage} = Compiler.compile(organization_id: @org, now: @now)

      refute "kyc.review_required" in Enum.map(bundle.rules, & &1.id)

      assert Enum.any?(
               lineage,
               &(&1.effect == :excluded_by_waiver and &1.source =~ "kyc.review_required")
             )
    end

    test "an expired waiver is excluded by the compiler: the rule returns" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)

      waive("kyc.review_required",
        starts_at: hours_after(@now, -48),
        expires_at: hours_after(@now, -1)
      )

      {:ok, bundle, _lineage} = Compiler.compile(organization_id: @org, now: @now)

      assert "kyc.review_required" in Enum.map(bundle.rules, & &1.id)
    end

    test "a waiver of a non-waivable global rule is refused" do
      activate(:global_non_waivable, AshCompliance.Test.RuleSets.GlobalNonWaivable)

      waive("kyc.jurisdiction_required", expires_at: hours_after(@now, 24))

      assert {:error, [message]} = Compiler.compile(organization_id: @org, now: @now)
      assert message =~ "non-waivable global layer"
      assert message =~ "kyc.jurisdiction_required"
    end

    test "a waiver for a rule no layer declares is refused" do
      waive("kyc.does_not_exist", expires_at: hours_after(@now, 24))

      assert {:error, [message]} = Compiler.compile(organization_id: @org, now: @now)
      assert message =~ "no active layer declares"
    end
  end

  describe "approved replacements" do
    test "a replacement displaces a tenant supplement" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)
      activate(:tenant_supplement, AshCompliance.Test.RuleSets.TenantSupplement)

      replacement_rule = %{
        mandatory_rule()
        | id: "kyc.welcome_review",
          severity: :critical,
          message: "replacement welcome review"
      }

      replace("kyc.welcome_review", rules_json([replacement_rule]))

      {:ok, bundle, lineage} = Compiler.compile(organization_id: @org, now: @now)

      rule = Enum.find(bundle.rules, &(&1.id == "kyc.welcome_review"))
      assert rule.severity == :critical
      assert Enum.any?(lineage, &(&1.effect == :replaced and &1.rule_count == 1))
    end

    test "a replacement of a global mandatory rule is refused" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)

      replacement_rule = %{mandatory_rule() | severity: :low}
      replace("kyc.valid_required", rules_json([replacement_rule]))

      assert {:error, [message]} = Compiler.compile(organization_id: @org, now: @now)
      assert message =~ "outranks approved overrides"
      assert message =~ "kyc.valid_required"
    end

    test "a replacement targeting an undeclared rule is refused" do
      replace("kyc.does_not_exist", rules_json([mandatory_rule()]))
      assert {:error, [message]} = Compiler.compile(organization_id: @org, now: @now)
      assert message =~ "no active layer declares"
    end
  end

  describe "profile refinement operations" do
    test "refine patches severity and message of a lower-ranked rule" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)
      activate(:tenant_strengthening, AshCompliance.Test.RuleSets.TenantStrengthening)

      profile_revision_with(%{
        "op" => "refine",
        "target" => "acct.balance_frozen",
        "severity" => "critical"
      })

      {:ok, bundle, _lineage} = Compiler.compile(organization_id: @org, now: @now)

      rule = Enum.find(bundle.rules, &(&1.id == "acct.balance_frozen"))
      assert rule.severity == :critical
    end

    test "refine of an undeclared rule is refused" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)

      profile_revision_with(%{
        "op" => "refine",
        "target" => "kyc.balance",
        "severity" => "critical"
      })

      assert {:error, [message]} = Compiler.compile(organization_id: @org, now: @now)
      assert message =~ "no active layer declares"
    end

    test "refine of a mandatory rule is refused" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)

      profile_revision_with(%{
        "op" => "refine",
        "target" => "kyc.valid_required",
        "severity" => "low"
      })

      assert {:error, [message]} = Compiler.compile(organization_id: @org, now: @now)
      assert message =~ "outranks profile refinements"
    end

    test "exclude removes a lower-ranked rule" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)
      activate(:tenant_strengthening, AshCompliance.Test.RuleSets.TenantStrengthening)
      profile_revision_with(%{"op" => "exclude", "target" => "acct.balance_frozen"})

      {:ok, bundle, _lineage} = Compiler.compile(organization_id: @org, now: @now)
      refute "acct.balance_frozen" in Enum.map(bundle.rules, & &1.id)
      # the baseline rules stay
      assert "kyc.valid_required" in Enum.map(bundle.rules, & &1.id)
    end

    test "exclude of a mandatory rule is refused" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)
      profile_revision_with(%{"op" => "exclude", "target" => "kyc.valid_required"})

      assert {:error, [message]} = Compiler.compile(organization_id: @org, now: @now)
      assert message =~ "outranks profile refinements"
    end

    test "parameterize is refused in v1" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)

      profile_revision_with(%{"op" => "parameterize", "target" => "kyc.valid_required"})

      assert {:error, [message]} = Compiler.compile(organization_id: @org, now: @now)
      assert message =~ "no parameter binding in v1"
    end
  end

  describe "combining" do
    test "the effective bundle carries the highest-precedence layer's algorithm" do
      activate(:global_mandatory, AshCompliance.Test.RuleSets.GlobalBaseline)

      strengthening =
        create_revision(
          :tenant_strengthening,
          "strengthener",
          Support.bundle_json(AshCompliance.Test.RuleSets.TenantStrengthening),
          combining: :permit_overrides
        )

      activate_revision(strengthening)

      {:ok, bundle, _lineage} = Compiler.compile(organization_id: @org, now: @now)

      # global mandatory outranks tenant strengthening, so its deny_overrides wins
      assert bundle.combining == :deny_overrides
    end

    test "with no mandatory layer present, the strengthening algorithm applies" do
      strengthening =
        create_revision(
          :tenant_strengthening,
          "strengthener",
          Support.bundle_json(AshCompliance.Test.RuleSets.TenantStrengthening),
          combining: :permit_overrides
        )

      activate_revision(strengthening)

      {:ok, bundle, _lineage} = Compiler.compile(organization_id: @org, now: @now)
      assert bundle.combining == :permit_overrides
    end
  end

  # --- helpers ------------------------------------------------------------------

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp hours_after(base, hours) do
    DateTime.add(base, hours * 3600, :second)
  end

  defp mandatory_rule do
    AshCompliance.Test.RuleSets.GlobalBaseline.__bundle__()
    |> Map.get(:rules)
    |> Enum.find(&(&1.id == "kyc.valid_required"))
  end

  defp rules_json(rules) do
    schema = AshCompliance.Test.RuleSets.GlobalBaseline.__bundle__().fact_schema
    AshRules.Ir.encode!(AshRules.Ir.Bundle.new(rules, schema))
  end

  defp activate(layer, module) do
    revision =
      create_revision(layer, "rules-" <> Support.unique(), Support.bundle_json(module))

    activate_revision(revision)
  end

  defp create_revision(layer, name, json, opts \\ []) do
    Support.rule_set_revision(
      organization_id: @org,
      name: name,
      layer: layer,
      combining: Keyword.get(opts, :combining, :deny_overrides),
      rules_json: json,
      content_hash: Support.unique(),
      # Fixture writes land inside the pinned compile clock's window (see
      # activate_revision); assertions are untouched.
      as_of: @now
    )
  end

  defp activate_revision(revision) do
    # The lifecycle chain writes as of the fixture clock, so the compile's
    # pinned `now` (@now) is the gather's as-of and finds these revisions
    # in force: the temporal gather answers "in force at the pin", and a
    # wall-now activation would postdate the pin (calendar drift between
    # the authored fixtures and the run). Assertions unchanged.
    revision
    |> AshCompliance.Domain.validate_rule_set_revision!(authorize?: false, as_of: @now)
    |> AshCompliance.Domain.approve_rule_set_revision!(authorize?: false, as_of: @now)
    |> AshCompliance.Domain.activate_rule_set_revision!(authorize?: false, as_of: @now)
  end

  defp waive(rule_id, opts) do
    AshCompliance.Domain.create_policy_override!(
      %{
        organization_id: @org,
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

  defp replace(rule_id, json) do
    # Phase 3 (temporal waivers): the in-force window is the period, and a
    # grant's period opens at its write instant. The fixture compiles at the
    # pinned @now, so the undated replacement is written AS OF that pinned
    # instant — without it the grant would open [real-now, ∞) and be
    # invisible to a compile clock set in its past. The assertions are
    # unchanged; this is the pinned-instant port of the old "nil starts_at
    # means always in force" convention.
    AshCompliance.Domain.create_policy_override!(
      %{
        organization_id: @org,
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

  defp profile_revision_with(operation) do
    {:ok, profile} =
      AshCompliance.Domain.create_profile(
        %{organization_id: @org, name: "profile-" <> Support.unique()},
        authorize?: false
      )

    {:ok, revision} =
      AshCompliance.Domain.create_profile_revision(
        %{
          profile_id: profile.id,
          version: "1",
          operations: [operation],
          content_hash: Support.unique()
        },
        authorize?: false
      )

    AshCompliance.Domain.create_tenant_policy_set!(
      %{
        organization_id: @org,
        name: "policy-set",
        profile_revision_ids: [revision.id]
      },
      authorize?: false
    )
  end
end
