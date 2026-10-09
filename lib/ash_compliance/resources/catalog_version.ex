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

  ## The publication window IS the period (Phase 3, temporal resources)

  This is a **temporal resource** (`strategy :context`, period attribute
  `valid_at`): a version's period opens at its publication instant and never
  ends — `[published_at, ∞)` over `utc_datetime_usec`. Append-only stays
  append-only: there is still no update action, so no period ever splits, and
  a plain read sees exactly the versions in force at the read's instant.

  * **Publishing** opens the period: the create opens `[as_of, ∞)`, where
    the write's `published_at` argument is the declared instant (default:
    now, pinned for the whole write). A `published_at` in the future is a
    **future-dated publication**: invisible to reads now, in force from that
    instant, no scheduler. A backdated one reconstructs history (a catalog
    import replaying an older document's publication date).
  * **"The latest version" is a containment read, not an insertion order.**
    Every version of a catalog is open-ended, so as of any instant all
    versions published up to then are in force; `latest_for_catalog` returns
    the one with the greatest publication instant. Read as-of a past `T`,
    the same read answers "the latest version as of `T`" — versions first
    published after `T` are not visible, so the answer travels backward
    correctly. This replaces the old `inserted_at`-desc convention, which
    misranked backdated publications.

  ## Where `published_at` went

  The stored column is gone; the period replaced it (one source of truth —
  a stored mirror of the publication instant could drift from the enforced
  period and did nothing the period does not). The **name survives as a
  public calculation** over the period (`range_lower`) so downstream code
  reading `version.published_at` keeps working, and it filters and sorts at
  the data layer (SQL `lower()`), like any read before the swap.

  ## Identities under periods

  `unique_version` and `unique_hash` are unchanged in the DSL; on a temporal
  resource they are unique **at every instant** (`UNIQUE (... WITHOUT
  OVERLAPS)`). For this resource that fires exactly as the old plain unique
  index did: every create opens an open-ended period at the write instant,
  so any two same-keyed versions overlap and the second is rejected.
  (History-under-one-key would need disjoint windows, which only updates
  can produce — and this resource has none by design.)
  """

  use AshCompliance.Resource, table: "catalog_versions"

  temporal do
    strategy(:context)
    attribute(:valid_at)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:catalog_id, :uuid, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:source, :string, public?: true)
    attribute(:content_hash, :string, allow_nil?: false, public?: true)

    timestamps()
  end

  calculations do
    # The declared publication instant, as plain reads. The period is the
    # single source of truth; this derives from it (SQL `lower()`,
    # filterable and sortable at the data layer), so a consumer reading
    # `version.published_at` gets the enforced bound — the instant the
    # version's period opens — and can never see a stale mirror.
    calculate(:published_at, :utc_datetime_usec, expr(range_lower(valid_at)),
      public?: true,
      description: "The instant the version was published — the period's lower bound (inclusive)."
    )
  end

  identities do
    # Unchanged names, now period-aware (`UNIQUE ... WITHOUT OVERLAPS`):
    # unique at every instant. With only open-ended creates, any two
    # same-keyed versions overlap, so these fire exactly as the old plain
    # unique indexes did. See the moduledoc.
    identity(:unique_version, [:catalog_id, :version])
    identity(:unique_hash, [:catalog_id, :content_hash])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([:catalog_id, :version, :source, :content_hash])

      # The declared publication instant — the period's lower bound. Not a
      # stored attribute any more; the name survives as the `range_lower`
      # calculation above (the waiver move).
      argument(:published_at, :utc_datetime_usec)

      change({AshCompliance.Resources.CatalogVersion.Changes.PublishAt, []})
    end

    read :get_by_id do
      get_by([:id])
    end

    read :latest_for_catalog do
      argument(:catalog_id, :uuid, allow_nil?: false)
      get?(true)

      # The as-of-now containment read. The temporal layer already scopes a
      # plain read to the versions whose period contains the read instant;
      # among those, latest = greatest publication instant — publication-
      # order containment replacing the insertion-order convention. The
      # `inserted_at` tail is only a total-order tiebreak for two versions
      # published at the same microsecond. Under `as_of` the identical read
      # answers "the latest version as of T" (see the moduledoc).
      prepare(build(sort: [published_at: :desc, inserted_at: :desc], limit: 1))
      filter(expr(catalog_id == ^arg(:catalog_id)))
    end
  end
end
