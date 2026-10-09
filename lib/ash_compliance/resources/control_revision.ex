# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.ControlRevision do
  @moduledoc """
  One versioned revision of a `AshCompliance.Resources.Control`: the
  statement text, its parameters, and citations — immutable once created.

  Text changes by appending a revision, so a finding recorded last year can
  always be explained by the control text that was in force when it fired.

  ## The period records when each status held (Phase 3, temporal resources)

  This is a **temporal resource** (`strategy :context`, period attribute
  `valid_at`). The lifecycle stays attributes — §1's design decision: a
  revision's pre-active states exist *before* any in-force window, which a
  single period cannot express, so `status` remains an attribute and the
  period records **when each status held**:

    * The create opens `[as_of, ∞)` carrying the created status (an OSCAL
      import creates `:active` directly; the default is `:draft`).
    * `activate` and `withdraw` are the same single-row updates they always
      were — under temporal, each **splits the period**: `[t₁,t₂)` carries
      `:draft`, `[t₂,t₃)` carries `:active`, `[t₃,∞)` carries `:withdrawn`.
      The guards and their refusal messages are unchanged
      ("only a draft control revision can be activated").
    * As-of reads return *what we believed at T* — the revision version
      whose period contains T. "In force at T" is the containment read:
      `active_for_control` filtered `status == :active`, whose periods
      contain the read instant.

  ## Multi-active is preserved, deliberately (§8.2 ruling iii)

  Repeated OSCAL imports leave several `:active` revisions per control, and
  this slice deliberately does NOT change that: `active_for_control` keeps
  its exact ordering (`status == :active`, newest period-lower first), so
  the export's `hd` consumer sees the newest active — byte-identical to the
  old `inserted_at` ordering, because an import-created active opens its
  period at its own insertion. There is **no** single-active exclusion on
  this resource; the `unique_revision` identity's `WITHOUT OVERLAPS` form
  constrains only same-`(control_id, version)` pairs (one revision's own
  history — adjacent splits never overlap), not "one active per control".
  Whether import should retire the prior active is the separate,
  named behavior-change ticket — not a mechanism-swap concern.

  ## `inserted_at` demoted

  The read ordering's "newest" moved from insertion order to the period's
  lower bound (`effective_from`): for import-created actives they coincide,
  but a revision activated later than it was drafted ranks by its
  activation instant — the instant the status actually took hold.
  """

  use AshCompliance.Resource, table: "control_revisions"

  temporal do
    strategy(:context)
    attribute(:valid_at)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:control_id, :uuid, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:statement, :string, public?: true)
    attribute(:params, {:array, :map}, default: [], public?: true)
    attribute(:citations, {:array, :string}, default: [], public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:draft, :active, :withdrawn]],
      default: :draft,
      allow_nil?: false,
      public?: true
    )

    timestamps()
  end

  calculations do
    # When the revision's current status took hold: the period's lower
    # bound (SQL `lower()`, filterable and sortable at the data layer).
    # This is the "newest" of the containment read's ordering — the
    # activation/publication instant of the status, not the row's
    # insertion.
    calculate(:effective_from, :utc_datetime_usec, expr(range_lower(valid_at)),
      public?: true,
      description:
        "The instant this revision's current status period opens (inclusive) — when the status took hold."
    )
  end

  identities do
    # Unchanged name, now period-aware (`UNIQUE ... WITHOUT OVERLAPS`):
    # one history per (control, version) — unique at every instant. A
    # lifecycle update splits the row into adjacent periods under the same
    # id and key; adjacent `[t₁,t₂) [t₂,∞)` never overlaps, so the row's
    # own history cannot false-conflict. Different versions never conflict
    # at all: this is NOT a single-active constraint (see the moduledoc).
    identity(:unique_revision, [:control_id, :version])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:control_id, :version, :statement, :params, :citations, :status])
    end

    update :activate do
      accept([])
      require_atomic?(false)

      validate attribute_equals(:status, :draft) do
        message("only a draft control revision can be activated")
      end

      change(set_attribute(:status, :active))
    end

    update :withdraw do
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :withdrawn))
    end

    read :get_by_id do
      get_by([:id])
    end

    # Every revision of a control, any status (the current period of each).
    # The import discipline reads this to rule per-control: unchanged
    # content skips, a used version string with changed content refuses.
    read :revisions_for_control do
      argument(:control_id, :uuid, allow_nil?: false)

      prepare(build(sort: [inserted_at: :desc]))

      filter(expr(control_id == ^arg(:control_id)))
    end

    read :active_for_control do
      argument(:control_id, :uuid, allow_nil?: false)

      # The as-of containment read with preserved ordering. The temporal
      # layer already scopes a plain read to the revision versions whose
      # period contains the read instant; `status == :active` is the
      # in-force filter, and "newest active" is the greatest
      # `effective_from` (the instant the active status took hold). The
      # `inserted_at` tail is only a total-order tiebreak. Under `as_of`,
      # the identical read answers "the actives in force at T, newest
      # first" — the export's `hd` therefore travels backward correctly.
      prepare(build(sort: [effective_from: :desc, inserted_at: :desc]))

      filter(expr(control_id == ^arg(:control_id) and status == :active))
    end
  end
end
