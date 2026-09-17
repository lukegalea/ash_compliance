# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyBundle do
  @moduledoc """
  The immutable, content-hashed compiled artifact: the effective
  `AshRules.Ir.Bundle` for an organization at a point in time.

  `compile` resolves the catalog/profile/tenant layers through
  `AshCompliance.Compiler` (which fetches active rule set revisions, profile
  refinements and valid overrides for the organization), serializes the
  resulting bundle, and stores the JSON with its content hash and the
  compiler version. The create action re-runs the resolution *inside the
  action*, so the stored bundle always reflects the layer state at compile
  time — ad-hoc inheritance is refused by the compiler, not trusted to the
  caller.

  `activate` is validate-before-activate: the stored JSON is decoded through
  `AshRules.Ir.decode/1` (full verifiers) before the bundle may go live. A
  bundle that no longer decodes — corrupted, or produced by an incompatible
  compiler — cannot be activated.
  """

  use AshCompliance.Resource, table: "policy_bundles"

  alias AshCompliance.Resources.PolicyBundle.CompileChange

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)
    attribute(:label, :string, public?: true)

    attribute(:rules_json, :string, allow_nil?: false, public?: true)
    attribute(:content_hash, :string, allow_nil?: false, public?: true)
    attribute(:manifest_revision, :string, allow_nil?: false, public?: true)
    attribute(:compiler_version, :string, allow_nil?: false, public?: true)

    attribute(:contributions, {:array, :map},
      default: [],
      public?: true,
      description: "The layers and revisions that contributed, as data (lineage)."
    )

    attribute(:status, :atom,
      constraints: [one_of: [:compiled, :active, :retired]],
      default: :compiled,
      allow_nil?: false,
      public?: true
    )

    attribute(:active_at, :utc_datetime_usec, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_hash_per_org, [:organization_id, :content_hash])
  end

  actions do
    defaults([:read])

    create :compile do
      primary?(true)
      accept([:organization_id, :label])
      argument(:now, :utc_datetime_usec)

      change(CompileChange)
    end

    update :activate do
      accept([])
      require_atomic?(false)

      validate attribute_equals(:status, :compiled) do
        message("only a compiled bundle can be activated")
      end

      change({CompileChange, stage: :activate})
    end

    update :retire do
      accept([])
      require_atomic?(false)

      validate attribute_equals(:status, :active) do
        message("only an active bundle can be retired")
      end

      change(set_attribute(:status, :retired))
    end

    read :get_by_id do
      get_by([:id])
    end

    read :active_for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      prepare(build(sort: [inserted_at: :desc], limit: 1))
      filter(expr(organization_id == ^arg(:organization_id) and status == :active))
    end

    read :decoded do
      argument(:id, :uuid, allow_nil?: false)
      get_by([:id])
    end
  end

  calculations do
    calculate :decoded_bundle, :term do
      calculation({AshCompliance.Resources.PolicyBundle.DecodedBundle, []})
    end
  end
end
