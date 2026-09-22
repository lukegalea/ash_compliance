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
  """

  use AshCompliance.Resource, table: "rule_set_revisions"

  alias AshCompliance.Compiler.Layer

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

    timestamps()
  end

  identities do
    identity(:unique_revision, [:organization_id, :name, :revision])
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
