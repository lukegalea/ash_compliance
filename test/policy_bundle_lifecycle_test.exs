# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.PolicyBundleLifecycleTest do
  @moduledoc """
  Rule-set revision lifecycle and the PolicyBundle compile → activate →
  retire transitions, including validate-before-activate.
  """

  use AshCompliance.DataCase, async: true

  alias AshCompliance.Test.Support

  @org Ecto.UUID.generate()

  test "a rule set revision moves draft → validated → approved → active" do
    revision = Support.rule_set_revision(name: "lifecycle-" <> Support.unique())

    assert revision.status == :draft

    revision = AshCompliance.Domain.validate_rule_set_revision!(revision, authorize?: false)

    assert revision.status == :validated

    revision = AshCompliance.Domain.approve_rule_set_revision!(revision, authorize?: false)

    assert revision.status == :approved

    revision = AshCompliance.Domain.activate_rule_set_revision!(revision, authorize?: false)

    assert revision.status == :active
  end

  test "a draft revision cannot jump straight to approved" do
    revision = Support.rule_set_revision(name: "lifecycle-" <> Support.unique())

    assert {:error, _} =
             AshCompliance.Domain.approve_rule_set_revision(revision, authorize?: false)
  end

  test "an active revision cannot be revoked, only retired" do
    revision = activate(Support.rule_set_revision(name: "lifecycle-" <> Support.unique()))

    assert {:error, _} =
             AshCompliance.Domain.revoke_rule_set_revision(revision, authorize?: false)

    retired = AshCompliance.Domain.retire_rule_set_revision!(revision, authorize?: false)

    assert retired.status == :retired
  end

  test "compile resolves the layers into a decoded, hash-pinned bundle" do
    activate(Support.rule_set_revision(name: "baseline-" <> Support.unique()))

    {:ok, bundle} =
      AshCompliance.Domain.compile_policy_bundle(
        %{organization_id: @org, label: "first compile"},
        authorize?: false
      )

    assert bundle.status == :compiled
    assert bundle.content_hash =~ ~r/^[0-9a-f]{64}$/
    assert bundle.compiler_version =~ ~r/^\d+$/

    {:ok, decoded} = AshRules.Ir.decode(bundle.rules_json)
    assert decoded.content_hash == bundle.content_hash
    assert Enum.map(decoded.rules, & &1.id) == ["kyc.review_required", "kyc.valid_required"]
  end

  test "activate refuses a bundle whose stored JSON no longer decodes" do
    activate(Support.rule_set_revision(name: "baseline-" <> Support.unique()))

    {:ok, bundle} =
      AshCompliance.Domain.compile_policy_bundle(%{organization_id: @org}, authorize?: false)

    # corrupt the stored JSON behind Ash's back (storage-level tampering)
    Ecto.Adapters.SQL.query!(
      AshCompliance.TestRepo,
      "UPDATE ash_compliance_policy_bundles SET rules_json = '{broken' WHERE id = $1",
      [
        Ecto.UUID.dump!(bundle.id)
      ]
    )

    reloaded = AshCompliance.Domain.get_policy_bundle_by_id!(bundle.id, authorize?: false)

    assert {:error, _} =
             AshCompliance.Domain.activate_policy_bundle(reloaded, authorize?: false)

    # the tampered bundle stays compiled, never active
    reloaded = AshCompliance.Domain.get_policy_bundle_by_id!(bundle.id, authorize?: false)
    assert reloaded.status == :compiled
  end

  test "retire takes an active bundle out of activation" do
    activate(Support.rule_set_revision(name: "baseline-" <> Support.unique()))

    bundle =
      AshCompliance.Domain.compile_policy_bundle!(%{organization_id: @org}, authorize?: false)
      |> AshCompliance.Domain.activate_policy_bundle!(authorize?: false)

    assert bundle.status == :active
    assert bundle.active_at != nil

    retired = AshCompliance.Domain.retire_policy_bundle!(bundle, authorize?: false)

    assert retired.status == :retired
  end

  defp activate(revision) do
    revision
    |> AshCompliance.Domain.validate_rule_set_revision!(authorize?: false)
    |> AshCompliance.Domain.approve_rule_set_revision!(authorize?: false)
    |> AshCompliance.Domain.activate_rule_set_revision!(authorize?: false)
  end
end
