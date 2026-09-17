# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.CatalogVersion do
  @moduledoc """
  An immutable revision of a `AshCompliance.Resources.Catalog`.

  Versions are append-only: republishing a catalog creates a new version row,
  never an update. `content_hash` is the SHA-256 over the canonical JSON of
  the version's control set, so two imports of the same document collapse to
  the same identity. `source` records lineage — where the revision came from
  (an OSCAL file, a URL, an author) and when.
  """

  use AshCompliance.Resource, table: "catalog_versions"

  attributes do
    uuid_primary_key(:id)

    attribute(:catalog_id, :uuid, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:source, :string, public?: true)
    attribute(:content_hash, :string, allow_nil?: false, public?: true)
    attribute(:published_at, :utc_datetime_usec, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_version, [:catalog_id, :version])
    identity(:unique_hash, [:catalog_id, :content_hash])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:catalog_id, :version, :source, :content_hash, :published_at])
    end

    read :get_by_id do
      get_by([:id])
    end

    read :latest_for_catalog do
      argument(:catalog_id, :uuid, allow_nil?: false)

      prepare(build(sort: [inserted_at: :desc], limit: 1))
      filter(expr(catalog_id == ^arg(:catalog_id)))
    end
  end
end
