# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.Profile do
  @moduledoc """
  A tailoring profile over a catalog: the stable identity a stream of
  immutable `AshCompliance.Resources.ProfileRevision` revisions hangs off.

  A profile's revisions declare tailoring *operations* (include, exclude,
  parameterize, refine, supplement, replace, waive) as data; the compiler
  resolves them against the layers they rank against.
  """

  use AshCompliance.Resource, table: "profiles"

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, public?: true)
    attribute(:catalog_id, :uuid, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:oscal_uuid, :string, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_name_per_org, [:organization_id, :name])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:organization_id, :catalog_id, :name, :oscal_uuid])
    end

    read :get_by_id do
      get_by([:id])
    end

    read :for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end
  end
end
