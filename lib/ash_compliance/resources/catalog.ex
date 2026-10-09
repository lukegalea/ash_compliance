# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.Catalog do
  @moduledoc """
  A compliance catalog: the stable identity a stream of immutable
  `AshCompliance.Resources.CatalogVersion` revisions hangs off.

  `organization_id` is `nil` for catalogs shared across tenants (the common
  case: an OSCAL import of a public baseline) and set for tenant-private
  catalogs. The catalog itself carries no content — all text, parameters and
  citations live on control revisions, and the catalog's content state is
  pinned by catalog versions.
  """

  use AshCompliance.Resource, table: "catalogs"

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:description, :string, public?: true)

    # The OSCAL document uuid, preserved across import/export round trips.
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
      accept([:organization_id, :name, :description, :oscal_uuid])
    end

    read :get_by_id do
      get_by([:id])
    end

    read :by_organization_and_name do
      argument(:organization_id, :uuid)
      argument(:name, :string, allow_nil?: false)
      get?(true)

      # The re-import identity lookup: the same (organization_id, name)
      # pair the unique_name_per_org index enforces. nil matches nil —
      # an import without an organization targets the shared namespace.
      filter(
        expr(
          name == ^arg(:name) and
            (organization_id == ^arg(:organization_id) or
               (is_nil(organization_id) and is_nil(^arg(:organization_id))))
        )
      )
    end

    read :for_organization do
      argument(:organization_id, :uuid)
      filter(expr(is_nil(organization_id) or organization_id == ^arg(:organization_id)))
    end
  end
end
