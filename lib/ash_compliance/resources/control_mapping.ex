# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.ControlMapping do
  @moduledoc """
  Maps a rule's gap reference onto a control — the seam between the rule
  engine's world (gap ids on findings) and the control plane's world
  (controls, revisions, catalogs).

  `AshCompliance.Resources.Finding` rows carry the gap id; this mapping is
  how a finding becomes an auditable control reference with jurisdiction and
  profile applicability.
  """

  use AshCompliance.Resource, table: "control_mappings"

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, public?: true)
    attribute(:gap, :string, allow_nil?: false, public?: true)
    attribute(:control_id, :string, allow_nil?: false, public?: true)
    attribute(:profile_revision_id, :uuid, public?: true)
    attribute(:jurisdiction, :string, public?: true)
    attribute(:notes, :string, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_gap_per_org, [:organization_id, :gap])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:organization_id, :gap, :control_id, :profile_revision_id, :jurisdiction, :notes])
    end

    read :get_by_id do
      get_by([:id])
    end

    read :by_gap do
      argument(:gap, :string, allow_nil?: false)
      argument(:organization_id, :uuid, allow_nil?: false)

      filter(expr(gap == ^arg(:gap) and organization_id == ^arg(:organization_id)))
    end
  end
end
