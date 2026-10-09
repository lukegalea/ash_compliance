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

  ## The config row is period-versioned (Phase 3, temporal resources)

  This is a **temporal resource** (`strategy :context`, period attribute
  `valid_at`): the per-org configuration row carries its id lists and its
  active-bundle pointer **through periods**. A membership change or a
  bundle change **splits the period** — `[t₁,t₂)` pins revision-list L0,
  `[t₂,∞)` pins L1 — so the payoff question, *which revisions was this
  tenant pinned to at T*, is a containment read: `for_organization` under
  `as_of: T` returns the exact set state that held at T.

  * **`set_active_bundle`** — the pointer change splits the period. The
    refuses-non-active-bundle check stays byte-identical and reads the
    bundle's **current** status on purpose: the pointer is a current-pointer
    (see below), and the check guards what is active at write time.
  * **`set_revisions`** — the membership change (added this slice): replaces
    the two id lists, splitting the period. The ids are data pointers, as
    always; the compiler resolves them.
  * **The compiler gather stays a CURRENT-pointer read** (flag 3's safe
    resolution): it reads the set without as-of, exactly as before the
    swap — the set says what applies *now*, and the compiler's
    determinism comes from the revision-side as-of it already pins (the
    slice-3 gather). Retroactive "what applied at T" is the as-of read's
    job, not the compile's.

  ## Identity under periods

  `one_per_organization` keeps its name and meaning, now period-aware
  (`UNIQUE (... WITHOUT OVERLAPS)`): one set **history** per organization —
  one row per instant. The set's own period splits are adjacent half-open
  periods under one id (self-split adjacency — the same adjacency proven on
  ControlRevision and RuleSetRevision), so churn never false-conflicts; a
  second, *distinct* set row for an org at an overlapping instant is still
  rejected, exactly as the old plain unique index did.
  """

  use AshCompliance.Resource, table: "tenant_policy_sets"

  temporal do
    strategy(:context)
    attribute(:valid_at)
  end

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
    # Unchanged name and meaning, now period-aware (`UNIQUE ... WITHOUT
    # OVERLAPS`): one set history per organization, one row per instant.
    # The set's own splits are adjacent and never false-conflict; a second
    # same-org row at an overlapping instant is rejected exactly as the old
    # plain unique index did. See the moduledoc.
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

    # The membership change (this slice): replace the pinned revision lists,
    # splitting the period. The ids are data pointers — the compiler
    # resolves them, exactly as on create.
    update :set_revisions do
      accept([:profile_revision_ids, :rule_set_revision_ids])
      require_atomic?(false)
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
