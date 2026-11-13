# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.RuleSet.DiffTest do
  @moduledoc """
  Two rule set revisions compared over the bundle each pins, never its text
  (`AshCompliance.RuleSet.Diff`). The bundle cases go through `AshRules.Ir.encode!`, so a
  change to the bundle's JSON shape that the differ does not follow fails here.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.RuleSet.Diff
  alias AshCompliance.Test.RuleSets.GlobalBaseline
  alias AshCompliance.Test.Support
  alias AshRules.Ir

  defp revision(bundle, overrides \\ %{}) do
    Map.merge(
      %{layer: :tenant_supplement, combining: :deny_overrides, rules_json: Jason.encode!(bundle)},
      overrides
    )
  end

  defp bundle(severity, overrides \\ %{}) do
    Map.merge(
      %{
        "combining" => "deny_overrides",
        "fact_schema" => [%{"name" => "licensed", "type" => "boolean"}],
        "rules" => [%{"id" => "licence", "name" => "Licence on file", "severity" => severity}]
      },
      overrides
    )
  end

  defp baseline_with(fun) do
    bundle = GlobalBaseline.__bundle__()
    %{bundle | rules: Enum.map(bundle.rules, fun)}
  end

  describe "diff/2" do
    test "aspects are listed in reading order, each with a label" do
      assert Keyword.keys(Diff.aspects()) == [:layer, :rules, :facts]
      assert Enum.all?(Diff.aspects(), fn {_aspect, label} -> is_binary(label) end)
    end

    test "a changed severity is one rule change, named by rule id and property" do
      assert {:ok,
              [
                %{
                  aspect: :rules,
                  kind: :changed,
                  subject: "licence",
                  option: "severity",
                  from: "low",
                  to: "high"
                }
              ]} = Diff.diff(revision(bundle("low")), revision(bundle("high")))
    end

    test "rules are added and removed by id" do
      second = %{"id" => "insurance", "name" => "Insurance on file", "severity" => "medium"}

      {:ok, changes} =
        Diff.diff(
          revision(bundle("low")),
          revision(bundle("low", %{"rules" => [second]}))
        )

      assert %{
               aspect: :rules,
               kind: :removed,
               subject: "licence",
               option: nil,
               from: %{"name" => "Licence on file", "severity" => "low"},
               to: nil
             } in changes

      assert %{aspect: :rules, kind: :added, subject: "insurance", option: nil} =
               Enum.find(changes, &(&1.kind == :added))

      assert length(changes) == 2
    end

    test "the layer and the combining algorithm are compared" do
      {:ok, changes} =
        Diff.diff(
          revision(bundle("low")),
          revision(bundle("low", %{"combining" => "permit_overrides"}), %{
            layer: :tenant_strengthening
          })
        )

      assert [
               %{
                 aspect: :layer,
                 subject: "combining",
                 from: "deny_overrides",
                 to: "permit_overrides"
               },
               %{
                 aspect: :layer,
                 subject: "layer",
                 from: "tenant_supplement",
                 to: "tenant_strengthening"
               }
             ] = changes
    end

    test "facts are compared by name" do
      {:ok, changes} =
        Diff.diff(
          revision(bundle("low")),
          revision(
            bundle("low", %{
              "fact_schema" => [
                %{"name" => "licensed", "type" => "boolean", "missing" => "unknown"},
                %{"name" => "insured", "type" => "boolean"}
              ]
            })
          )
        )

      assert [
               %{aspect: :facts, kind: :added, subject: "insured"},
               %{
                 aspect: :facts,
                 kind: :changed,
                 subject: "licensed",
                 option: "missing",
                 from: nil,
                 to: "unknown"
               }
             ] = changes
    end

    test "a bundle that does not decode is an error, not an empty rule set" do
      good = revision(bundle("low"))

      assert Diff.diff(%{good | rules_json: "not json"}, good) ==
               {:error, :unreadable_bundle}

      assert Diff.diff(good, %{good | rules_json: ~s({"combining": "deny_overrides"})}) ==
               {:error, :unreadable_bundle}

      assert Diff.diff(good, %{layer: :tenant_supplement}) == {:error, :unreadable_bundle}
    end

    test "every change is a plain map in one of the aspects" do
      {:ok, changes} =
        Diff.diff(
          revision(bundle("low")),
          revision(bundle("high", %{"fact_schema" => []}), %{layer: :global_mandatory})
        )

      aspects = Keyword.keys(Diff.aspects())
      assert changes != []

      for change <- changes do
        refute is_struct(change)
        assert change.aspect in aspects
        assert Map.keys(change) |> Enum.sort() == [:aspect, :from, :kind, :option, :subject, :to]
      end
    end
  end

  describe "over encoded bundles" do
    test "re-encoding the same bundle changes nothing; an edited rule does" do
      json = Ir.encode!(GlobalBaseline.__bundle__())
      old = %{layer: :global_mandatory, rules_json: json}
      pretty = json |> Jason.decode!() |> Jason.encode!(pretty: true)

      assert pretty != json
      assert Diff.diff(old, %{old | rules_json: pretty}) == {:ok, []}

      edited =
        baseline_with(fn
          %{id: "kyc.review_required"} = rule -> %{rule | severity: :critical}
          rule -> rule
        end)

      assert {:ok,
              [
                %{
                  aspect: :rules,
                  kind: :changed,
                  subject: "kyc.review_required",
                  option: "severity",
                  from: "high",
                  to: "critical"
                }
              ]} = Diff.diff(old, %{old | rules_json: Ir.encode!(edited)})
    end

    test "two stored revisions compare by the bundles they pin" do
      first = Support.rule_set_revision([])

      dropped =
        baseline_with(fn rule -> rule end)
        |> Map.update!(:rules, &Enum.reject(&1, fn rule -> rule.id == "kyc.valid_required" end))

      second =
        Support.rule_set_revision(
          name: first.name,
          revision: "2",
          rules_json: Ir.encode!(dropped)
        )

      assert {:ok, []} = Diff.diff(first, first)

      assert {:ok, [%{aspect: :rules, kind: :removed, subject: "kyc.valid_required"}]} =
               Diff.diff(first, second)
    end
  end
end
