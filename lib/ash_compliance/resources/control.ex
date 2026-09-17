# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.Control do
  @moduledoc """
  A control's stable semantic identity (`control_id`, e.g.
  `"kyc.valid_required"`), separate from any versioned text.

  Rule gap references point at controls through this stable id — that is what
  makes findings durable across control text revisions. The versioned
  statement, parameters and citations live on
  `AshCompliance.Resources.ControlRevision`.
  """

  use AshCompliance.Resource, table: "controls"

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, public?: true)
    attribute(:catalog_id, :uuid, public?: true)
    attribute(:control_id, :string, allow_nil?: false, public?: true)
    attribute(:title, :string, public?: true)
    attribute(:family, :string, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_control_id, [:organization_id, :control_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:organization_id, :catalog_id, :control_id, :title, :family])
    end

    read :get_by_id do
      get_by([:id])
    end

    read :by_control_id do
      argument(:control_id, :string, allow_nil?: false)
      argument(:organization_id, :uuid)

      filter(expr(is_nil(organization_id) or organization_id == ^arg(:organization_id)))
      filter(expr(control_id == ^arg(:control_id)))
    end

    read :for_catalog do
      argument(:catalog_id, :uuid, allow_nil?: false)
      filter(expr(catalog_id == ^arg(:catalog_id)))
    end
  end
end
