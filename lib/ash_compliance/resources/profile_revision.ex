# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.ProfileRevision do
  @moduledoc """
  One immutable revision of a `AshCompliance.Resources.Profile`.

  Tailoring operations are stored as data — a list of typed operation maps in
  declaration order — never as logic:

      %{
        "op" => "refine",
        "rule_id" => "kyc.valid_required",
        "severity" => "high",
        "message" => "jurisdictional policy requires faster remediation"
      }

  Supported operations:

    * `include` — names a control/rule the profile carries (documentary)
    * `exclude` — removes a rule from the effective bundle
    * `parameterize` — sets named parameters (stored; compiler v1 refuses
      rules that consume parameters, since the IR has no parameter binding)
    * `refine` — patches a rule's `severity` and/or `message`
    * `supplement` — adds guidance text against a control (documentary)
    * `replace` / `waive` — these are *overrides* with approval semantics;
      they belong in `AshCompliance.Resources.PolicyOverride`, and a profile
      revision carrying them is refused at compile time

  `content_hash` pins the revision: identical operations produce identical
  hashes.

  ## The period opens at creation (Phase 3, temporal resources)

  This is a **temporal resource** (`strategy :context`, period attribute
  `valid_at`). Profile revisions are **create+read only** — append-only by
  absence of actions — so a revision's period opens at its creation instant
  and never ends: nothing ever splits it. A plain read is the as-of-now
  containment read; `Ash.Query.as_of/2` (or the `as_of:` option) travels
  through code interfaces, so "the latest revision as of T" and "the
  revisions that existed at T" are containment queries, not insertion-order
  conventions.

  `latest_for_profile` keeps its ordering contract, restated temporally:
  newest period-lower first (the `inserted_at` tail is only a same-second
  tiebreak). Under `as_of`, the identical read answers "the latest revision
  as of T" — revisions created after T are not visible, so the answer
  travels backward correctly.

  `unique_revision` keeps its name and meaning, now period-aware (`UNIQUE
  ... WITHOUT OVERLAPS`): unique at every instant. With only open-ended
  creates, any two same-keyed revisions overlap, so it fires exactly as the
  old plain unique index did. (No update actions exist, so a row can never
  conflict with its own history — the self-split question is structurally
  unreachable here.)
  """

  use AshCompliance.Resource, table: "profile_revisions"

  alias AshCompliance.Oscal.ProfileOperation

  temporal do
    strategy(:context)
    attribute(:valid_at)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:profile_id, :uuid, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:source, :string, public?: true)
    attribute(:operations, {:array, :map}, default: [], public?: true)
    attribute(:content_hash, :string, allow_nil?: false, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_revision, [:profile_id, :version])
  end

  calculations do
    # When the revision came into force: the period's lower bound (SQL
    # `lower()`, filterable and sortable at the data layer) — the creation
    # instant. This is the "newest" of the containment read's ordering;
    # microsecond-granular where `inserted_at` is second-granular, so it
    # also breaks same-second ties deterministically.
    calculate(:effective_from, :utc_datetime_usec, expr(range_lower(valid_at)),
      public?: true,
      description: "The instant the revision's period opens (inclusive) — its creation."
    )
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:profile_id, :version, :source, :operations, :content_hash])
      validate({ProfileOperation.ValidateOperations, []})
    end

    read :get_by_id do
      get_by([:id])
    end

    read :latest_for_profile do
      argument(:profile_id, :uuid, allow_nil?: false)
      get?(true)

      # The as-of-now containment read with preserved ordering. The
      # temporal layer already scopes a plain read to the revisions whose
      # period contains the read instant; newest = greatest period-lower
      # (the creation instant). The `inserted_at` tail is only a
      # total-order tiebreak for revisions created in the same second.
      prepare(build(sort: [effective_from: :desc, inserted_at: :desc], limit: 1))
      filter(expr(profile_id == ^arg(:profile_id)))
    end

    read :for_profile do
      argument(:profile_id, :uuid, allow_nil?: false)
      prepare(build(sort: [inserted_at: :desc]))
      filter(expr(profile_id == ^arg(:profile_id)))
    end
  end
end
