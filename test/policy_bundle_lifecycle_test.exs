# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.PolicyBundleLifecycleTest do
  @moduledoc """
  Rule-set revision lifecycle and the PolicyBundle compile → activate →
  retire transitions, including validate-before-activate.
  """

  use AshCompliance.DataCase, async: true

  alias AshCompliance.Resources.{PolicyBundle, RuleSetRevision}
  alias AshCompliance.Test.Support

  @org Ecto.UUID.generate()

  test "a rule set revision moves draft → validated → approved → active" do
    revision = Support.rule_set_revision(name: "lifecycle-" <> Support.unique())

    assert revision.status == :draft

    revision =
      revision
      |> Ash.Changeset.for_update(:validate)
      |> Ash.update!(authorize?: false)

    assert revision.status == :validated

    revision =
      revision
      |> Ash.Changeset.for_update(:approve)
      |> Ash.update!(authorize?: false)

    assert revision.status == :approved

    revision =
      revision
      |> Ash.Changeset.for_update(:activate)
      |> Ash.update!(authorize?: false)

    assert revision.status == :active
  end

  test "a draft revision cannot jump straight to approved" do
    revision = Support.rule_set_revision(name: "lifecycle-" <> Support.unique())

    assert {:error, _} =
             revision
             |> Ash.Changeset.for_update(:approve)
             |> Ash.update(authorize?: false)
  end

  test "an active revision cannot be revoked, only retired" do
    revision = activate(Support.rule_set_revision(name: "lifecycle-" <> Support.unique()))

    assert {:error, _} =
             revision
             |> Ash.Changeset.for_update(:revoke)
             |> Ash.update(authorize?: false)

    retired =
      revision
      |> Ash.Changeset.for_update(:retire)
      |> Ash.update!(authorize?: false)

    assert retired.status == :retired
  end

  test "compile resolves the layers into a decoded, hash-pinned bundle" do
    activate(Support.rule_set_revision(name: "baseline-" <> Support.unique()))

    {:ok, bundle} =
      Ash.create(
        PolicyBundle,
        %{organization_id: @org, label: "first compile"},
        action: :compile
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
      Ash.create(PolicyBundle, %{organization_id: @org}, action: :compile)

    # corrupt the stored JSON behind Ash's back (storage-level tampering)
    Ecto.Adapters.SQL.query!(
      AshCompliance.TestRepo,
      "UPDATE ash_compliance_policy_bundles SET rules_json = '{broken' WHERE id = $1",
      [
        Ecto.UUID.dump!(bundle.id)
      ]
    )

    reloaded = Ash.get!(PolicyBundle, bundle.id, authorize?: false)

    assert {:error, _} =
             reloaded
             |> Ash.Changeset.for_update(:activate)
             |> Ash.update(authorize?: false)

    # the tampered bundle stays compiled, never active
    reloaded = Ash.get!(PolicyBundle, bundle.id, authorize?: false)
    assert reloaded.status == :compiled
  end

  test "retire takes an active bundle out of activation" do
    activate(Support.rule_set_revision(name: "baseline-" <> Support.unique()))

    bundle =
      Ash.create!(PolicyBundle, %{organization_id: @org}, action: :compile)
      |> Ash.Changeset.for_update(:activate)
      |> Ash.update!(authorize?: false)

    assert bundle.status == :active
    assert bundle.active_at != nil

    retired =
      bundle
      |> Ash.Changeset.for_update(:retire)
      |> Ash.update!(authorize?: false)

    assert retired.status == :retired
  end

  defp activate(revision) do
    revision
    |> Ash.Changeset.for_update(:validate)
    |> Ash.update!(authorize?: false)
    |> Ash.Changeset.for_update(:approve)
    |> Ash.update!(authorize?: false)
    |> Ash.Changeset.for_update(:activate)
    |> Ash.update!(authorize?: false)
  end
end
