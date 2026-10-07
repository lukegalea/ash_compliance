# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyOverride do
  @moduledoc """
  An approval-bearing exception: a **replacement** of a rule, or a **waiver**
  of one, with the accountability the compliance framework requires.

  Every override carries an approver and a reason. Waivers carry hard
  requirements enforced by validations:

    * `expires_at` — bounded time; a waiver cannot be open-ended
    * `compensating_controls` — at least one, non-empty
    * scope — `subject_type`/`subject_id` (nil both = organization-wide)

  ## The in-force window IS the period (Phase 3, temporal resources)

  This is a **temporal resource** (`strategy :context`, period attribute
  `valid_at`): a half-open `[starts_at, expires_at)` over
  `utc_datetime_usec` — the same boundary semantics the old read filter
  expressed by hand (`starts_at <= now`, `expires_at > now`), now stored and
  enforced by PostgreSQL 18 instead of convention.

  * **Granting** opens the period: the create opens `[as_of, ∞)`, where the
    write's `as_of` is the `starts_at` argument (default: now, pinned for the
    whole write). A `starts_at` in the future is a **future-dated waiver**:
    invisible to reads now, in force from that instant, no scheduler.
  * **Expiry is physical.** For a bounded override, the grant truncates the
    just-opened period at `expires_at` in the same transaction
    (`Changes.BoundWindow`), so the stored period IS
    `[starts_at, expires_at)`. After it, no version is in force — a waiver
    lapsing returns the rule to the effective bundle without any action
    being taken, and without the bound ever drifting from storage.
  * **Non-overlap is DB-enforced.** One waiver per
    `(organization_id, rule_id, scope_key)` may be in force at any instant
    (the `one_in_force_per_scope` identity — a `UNIQUE (... WITHOUT
    OVERLAPS)` GiST exclusion). The double-granted waiver is now impossible:
    a second overlapping grant is rejected by the database. Successive
    waivers (non-overlapping windows) remain fine; that is history, not
    overlap. `scope_key` is the derived non-null stand-in for the nullable
    scope pair — GiST equality never conflicts on NULLs, so keying the
    exclusion directly on the scope columns would leave organization-wide
    waivers unconstrained, i.e. still double-grantable.

  ## Where `starts_at`/`expires_at` went

  The stored columns are gone; the period replaced them (one source of
  truth — a stored bound could drift from the enforced period, e.g. on the
  data-layer truncate, and did nothing the period does not). The **names
  survive as public calculations** over the period (`range_lower` /
  `range_upper`) so downstream code reading `waiver.starts_at` /
  `waiver.expires_at` keeps working (`load: [:starts_at, :expires_at]` on
  reads; they filter at the data layer too — SQL `lower()`/`upper()`).
  `expires_at` of an evergreen override reads `nil`, exactly as before.

  ## Reads

  Every read is a point in time. Plain reads return the state in force
  **now**; `Ash.Query.as_of/2` (or the `as_of` option) travels through code
  interfaces, and `valid_for_organization/2` pins the instant from its `now`
  argument — which is how the compiler keeps its deterministic compile
  clock: the pinned `now` becomes the read's `as_of`, evaluated by the
  database against the enforced periods.
  """

  use AshCompliance.Resource, table: "policy_overrides"

  temporal do
    strategy(:context)
    attribute(:valid_at)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)

    attribute(:kind, :atom,
      constraints: [one_of: [:replace, :waive]],
      allow_nil?: false,
      public?: true
    )

    attribute(:rule_id, :string, allow_nil?: false, public?: true)
    attribute(:reason, :string, allow_nil?: false, public?: true)
    attribute(:approver, :string, allow_nil?: false, public?: true)
    attribute(:approved_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    attribute(:scope_subject_type, :string, public?: true)
    attribute(:scope_subject_id, :string, public?: true)

    # The non-null stand-in for the nullable `(scope_subject_type,
    # scope_subject_id)` pair in the non-overlap exclusion. GiST `WITH =`
    # never conflicts on NULLs, so the identity cannot key the raw columns:
    # organization-wide waivers (both scopes nil) would never conflict and
    # stay double-grantable. Derived by `Changes.DeriveScopeKey`; nil
    # scopes hash to a sentinel so "organization-wide" keys
    # deterministically. Not public: it is constraint plumbing.
    attribute(:scope_key, :string, allow_nil?: false, public?: false)

    attribute(:compensating_controls, {:array, :string}, default: [], public?: true)

    attribute(:replacement_rules_json, :string,
      public?: true,
      description: "For :replace overrides — the serialized replacement rule set JSON."
    )

    timestamps()
  end

  calculations do
    # The declared window, as plain reads. The period is the single source
    # of truth; these derive from it (SQL `lower()`/`upper()`, filterable),
    # so a consumer reading `waiver.expires_at` gets the enforced bound —
    # nil for an evergreen override — and can never see a stale mirror.
    calculate(:starts_at, :utc_datetime_usec, expr(range_lower(valid_at)),
      public?: true,
      description: "The instant the override's period opens (inclusive)."
    )

    calculate(:expires_at, :utc_datetime_usec, expr(range_upper(valid_at)),
      public?: true,
      description:
        "The instant the override's period ends (exclusive); nil for an evergreen override."
    )
  end

  identities do
    # The double-grant killer: one override in force per (organization,
    # rule, scope) at ANY instant. Emitted as a `UNIQUE (... WITHOUT
    # OVERLAPS)` GiST exclusion over `valid_at` — overlapping windows are
    # rejected by the database, while non-overlapping history under the
    # same key stays legal. Keyed on the derived `scope_key` (see the
    # attribute's note) because NULLs never conflict in GiST.
    identity(:one_in_force_per_scope, [:organization_id, :rule_id, :scope_key])
  end

  actions do
    # Plain reads return the state in force now; as_of travels the shared
    # context. :destroy is the temporal truncate the grant's
    # `Changes.BoundWindow` uses to physically bound a waiver's period.
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :organization_id,
        :kind,
        :rule_id,
        :reason,
        :approver,
        :approved_at,
        :scope_subject_type,
        :scope_subject_id,
        :compensating_controls,
        :replacement_rules_json
      ])

      # The declared in-force window. `starts_at` sets the write instant
      # (the period's lower bound — pass a future instant to future-date a
      # waiver); `expires_at` physically bounds the period. Neither is a
      # stored attribute any more — see the moduledoc.
      argument(:starts_at, :utc_datetime_usec)
      argument(:expires_at, :utc_datetime_usec)

      # Declaration order matters: the changes resolve `scope_key` and pin
      # the write instant from `starts_at` before the validation reads them.
      change({AshCompliance.Resources.PolicyOverride.Changes.DeriveScopeKey, []})
      change({AshCompliance.Resources.PolicyOverride.Changes.BoundWindow, []})

      validate({AshCompliance.Resources.PolicyOverride.ValidateOverride, []})
    end

    read :get_by_id do
      get_by([:id])
    end

    read :valid_for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      filter(expr(organization_id == ^arg(:organization_id)))

      # The in-force-at-`now` read: the pinned instant becomes the query's
      # `as_of`, and the database answers with the overrides whose enforced
      # period contains it (index-backed containment). This is what keeps
      # the compiler's deterministic compile clock working unchanged.
      prepare({AshCompliance.Resources.PolicyOverride.Preparations.AsOfNow, []})
    end
  end
end
