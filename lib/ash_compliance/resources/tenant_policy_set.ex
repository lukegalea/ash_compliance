# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.TenantPolicySet do
  @moduledoc """
  A tenant's compliance program: which profile revisions and tenant-layer
  rule set revisions apply, and which `AshCompliance.Resources.PolicyBundle`
  is currently active.

  One per organization (unique `organization_id`). The compiler reads the
  tenant policy set to know which contributions to resolve — it never accepts
  ad-hoc layer lists from callers.
  """

  use AshCompliance.Resource, table: "tenant_policy_sets"

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)
    attribute(:name, :string, public?: true)

    attribute(:profile_revision_ids, {:array, :uuid}, default: [], public?: true)
    attribute(:rule_set_revision_ids, {:array, :uuid}, default: [], public?: true)
    attribute(:active_policy_bundle_id, :uuid, public?: true)

    timestamps()
  end

  identities do
    identity(:one_per_organization, [:organization_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:organization_id, :name, :profile_revision_ids, :rule_set_revision_ids])
    end

    update :set_active_bundle do
      accept([:active_policy_bundle_id])
      require_atomic?(false)
      change({AshCompliance.Resources.TenantPolicySet.SetActiveBundle, []})
    end

    read :for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      get?(true)
      prepare(build(limit: 1))
      filter(expr(organization_id == ^arg(:organization_id)))
    end

    read :get_by_id do
      get_by([:id])
    end
  end
end
