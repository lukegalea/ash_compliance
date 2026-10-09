# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.RuleSetRevision do
  @moduledoc """
  One immutable revision of a rule set, with a lifecycle.

  A rule set revision pins a compiled `AshRules` rule set (the bundle JSON of
  a `use AshRules` module, or an equivalent decoded tenant bundle) at a point
  in time, tagged with the **layer** it contributes to and the combining
  algorithm its layer declares:

    * `:global_non_waivable` — outranks everything; can never be waived or
      replaced
    * `:global_mandatory` — outranks everything except non-waivable globals;
      may be waived (with approval) but never replaced
    * `:profile_refinement` — catalog tailoring output
    * `:tenant_strengthening` — tenant rules that tighten the baseline
    * `:tenant_supplement` — tenant additions that cannot override anything

  Status lifecycle: `draft → validated → approved → active → retired |
  revoked`. Only `:active` revisions participate in compilation.

  `rules_json` is the serialized `AshRules.Ir.Bundle` JSON; `content_hash` is
  its content hash, so two revisions of the same content are interchangeable.

  ## The period records when each status held (Phase 3, temporal resources)

  This is a **temporal resource** (`strategy :context`, period attribute
  `valid_at`). The lifecycle stays attributes — §1's design decision: a
  revision's pre-active states exist *before* any in-force window, which a
  single period cannot express, so `status` remains an attribute and the
  period records **when each status held**:

    * The `:draft` create opens `[as_of, ∞)`.
    * Each of the five lifecycle updates (`validate`, `approve`, `activate`,
      `retire`, `revoke`) is the same single-row update it always was — same
      guards, byte-identical refusal messages — but under temporal it
      **splits the period**: `[t₁,t₂)` carries `:draft`, `[t₂,t₃)`
      `:validated`, and so on. As-of reads return *what we believed at T*,
      which is correct provenance, for free.
    * **"Revision in force at T"** is a containment query:
      `active_for_organization` keeps its `status == :active` filter and its
      `organization_id` argument (nil-org revisions stay global), and the
      as-of instant comes from the read's context — plain reads are
      in-force-now; `Ash.Query.as_of/2` (or the `as_of:` option) travels
      through code interfaces, per the waiver pattern. The compiler's
      gather pins its `now` as the read's as-of: one instant for the whole
      gather, deterministic compile preserved.
    * **Writes: no actor-as-of anywhere.** Plain lifecycle writes split at
      the house clock (wall-now at the compile clock's second granularity
      — see `Changes.PinWriteInstant`). The one declared-instant write is
      `activate`'s `effective_at` argument (the waiver form): pass a future
      instant to **future-date an activation** — invisible to reads now,
      in force from that instant, no scheduler. Absent, activation splits
      at the house clock.

  ## The double-activation killer: `active_key` (§1's dividend)

  Today nothing prevented two simultaneously-active revisions of one name;
  only discipline (and the compiler's merge tolerance) held the line.
  Temporal kills it with the waiver's `scope_key` trick **inverted**:

    * `active_key` is a derived column — `"active"` iff `status == :active`,
      NULL otherwise (`Changes.DeriveActiveKey`, run on every create and
      update).
    * The `one_active_per_name` identity keys `(organization_id, name,
      active_key)` into a `UNIQUE (... WITHOUT OVERLAPS)` GiST exclusion.
      **GiST equality never conflicts on NULLs**, so non-active rows never
      conflict and the exclusion constrains only genuinely-active rows:
      activating a second revision of the same name while one is in force
      is rejected by the database. Retire (or revoke-after-activate is
      refused; retire is the path) NULLs the key, so history never blocks a
      successor.
    * **This is NOT the waiver's `scope_key` trick** — do not "simplify" one
      into the other. `scope_key` is a *non-null stand-in* for nullable
      columns: it substitutes a sentinel so NULL-scoped rows DO conflict.
      `active_key` is the inverse: a *null-when-inactive* flag: it goes NULL
      precisely so non-active rows DON'T conflict. Same GiST property, two
      opposite purposes.
    * Edge deliberately preserved: `organization_id` is nullable (global
      revisions), and GiST NULL semantics apply to it too — two global
      (nil-org) actives of one name do not conflict, exactly as today's
      plain unique index never constrained nil-org pairs. Org-scoped
      double-activation — the case discipline was guarding — is what became
      impossible.

  `unique_revision` keeps its name and meaning (one history per
  `(organization_id, name, revision)`): under periods it is unique *at every
  instant*, and a row's own lifecycle splits are adjacent half-open periods
  — `[t₁,t₂)` meets `[t₂,∞)` without overlapping — so churn never
  false-conflicts with itself.
  """

  use AshCompliance.Resource, table: "rule_set_revisions"

  alias AshCompliance.Compiler.Layer

  temporal do
    strategy(:context)
    attribute(:valid_at)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:revision, :string, allow_nil?: false, default: "1", public?: true)

    attribute(:layer, :atom,
      constraints: [one_of: Layer.layers()],
      allow_nil?: false,
      public?: true
    )

    attribute(:combining, :atom,
      constraints: [one_of: AshRules.Combining.algorithms()],
      default: :deny_overrides,
      allow_nil?: false,
      public?: true
    )

    attribute(:source_module, :string,
      public?: true,
      description: "The `use AshRules` module this revision was exported from, if any."
    )

    attribute(:rules_json, :string,
      allow_nil?: false,
      public?: true,
      description: "The serialized AshRules.Ir.Bundle JSON."
    )

    attribute(:content_hash, :string, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: Layer.statuses()],
      default: :draft,
      allow_nil?: false,
      public?: true
    )

    # The null-when-inactive flag in the `one_active_per_name` exclusion —
    # see the moduledoc for why it is the waiver `scope_key` trick inverted,
    # and why the two must not be conflated. Not public: constraint plumbing.
    attribute(:active_key, :string, public?: false)

    timestamps()
  end

  identities do
    # Unchanged name and meaning, now period-aware (`UNIQUE ... WITHOUT
    # OVERLAPS`): one history per (organization, name, revision), unique at
    # every instant. A row's own lifecycle splits are adjacent half-open
    # periods and never false-conflict; see the moduledoc.
    identity(:unique_revision, [:organization_id, :name, :revision])

    # The double-activation killer: one ACTIVE revision per (organization,
    # name) at ANY instant. Non-active rows carry a NULL active_key and GiST
    # equality never conflicts on NULLs, so drafts/approved/retired history
    # is unconstrained — only genuinely-active rows can collide. NOT the
    # waiver's scope_key trick (which keeps NULL-scoped rows conflicting);
    # see the moduledoc.
    identity(:one_active_per_name, [:organization_id, :name, :active_key])
  end

  changes do
    # Every create and update derives the exclusion key from the status it
    # is writing, so the key can never drift from the status that owns it.
    change({AshCompliance.Resources.RuleSetRevision.Changes.DeriveActiveKey, []},
      on: [:create, :update]
    )

    # Every create and update pins its write instant: an explicit `as_of`,
    # else `activate`'s `effective_at` argument, else the house clock
    # (seconds-truncated now — the compile clock's granularity; see the
    # change module for why the default is load-bearing).
    change({AshCompliance.Resources.RuleSetRevision.Changes.PinWriteInstant, []},
      on: [:create, :update]
    )
  end

  actions do
    defaults([:read])

    create :draft do
      primary?(true)

      accept([
        :organization_id,
        :name,
        :revision,
        :layer,
        :combining,
        :source_module,
        :rules_json,
        :content_hash
      ])
    end

    update :validate do
      accept([])
      # Single-row status transitions with house-style refusal messages;
      # validations run in Elixir, so no SQL-side error function is needed.
      require_atomic?(false)

      validate attribute_equals(:status, :draft) do
        message("only a draft rule set revision can be validated")
      end

      change(set_attribute(:status, :validated))
    end

    update :approve do
      accept([])
      # Single-row status transitions with house-style refusal messages;
      # validations run in Elixir, so no SQL-side error function is needed.
      require_atomic?(false)

      validate attribute_equals(:status, :validated) do
        message("only a validated rule set revision can be approved")
      end

      change(set_attribute(:status, :approved))
    end

    update :activate do
      accept([])
      # Single-row status transitions with house-style refusal messages;
      # validations run in Elixir, so no SQL-side error function is needed.
      require_atomic?(false)

      validate attribute_equals(:status, :approved) do
        message("only an approved rule set revision can be activated")
      end

      # The declared activation instant (the waiver form, §1): absent, the
      # write splits at the house clock; a future instant future-dates the
      # activation — invisible to reads now, in force from that instant,
      # no scheduler. (`PinWriteInstant` resolves it; see the changes
      # block.)
      argument(:effective_at, :utc_datetime_usec)

      change(set_attribute(:status, :active))
    end

    update :retire do
      accept([])
      # Single-row status transitions with house-style refusal messages;
      # validations run in Elixir, so no SQL-side error function is needed.
      require_atomic?(false)

      validate attribute_equals(:status, :active) do
        message("only an active rule set revision can be retired")
      end

      change(set_attribute(:status, :retired))
    end

    update :revoke do
      accept([])
      # Single-row status transitions with house-style refusal messages;
      # validations run in Elixir, so no SQL-side error function is needed.
      require_atomic?(false)

      validate attribute_in(:status, [:draft, :validated, :approved]) do
        message("only an unactivated rule set revision can be revoked")
      end

      change(set_attribute(:status, :revoked))
    end

    read :get_by_id do
      get_by([:id])
    end

    read :active_for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)

      # The in-force-at-the-read-instant containment read (§1). The
      # temporal layer scopes a plain read to the revision versions whose
      # period contains the read instant; `status == :active` is the
      # in-force filter, and the nil-org global semantics are unchanged.
      # Under `as_of`, the identical read answers "in force at T" — which
      # is how the compiler's gather turns its pinned `now` into the read
      # instant, one instant for the whole gather.
      filter(
        expr(
          status == :active and
            (is_nil(organization_id) or organization_id == ^arg(:organization_id))
        )
      )
    end

    read :for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)

      prepare(build(sort: [inserted_at: :desc]))

      filter(expr(organization_id == ^arg(:organization_id)))
    end
  end
end
