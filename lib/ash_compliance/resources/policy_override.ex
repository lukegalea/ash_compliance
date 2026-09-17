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

  Expiry is evaluated at compile time against the compile clock: expired
  waivers are excluded by the compiler, so a waiver lapsing returns the rule
  to the effective bundle without any action being taken.
  """

  use AshCompliance.Resource, table: "policy_overrides"

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

    attribute(:starts_at, :utc_datetime_usec, public?: true)
    attribute(:expires_at, :utc_datetime_usec, public?: true)

    attribute(:scope_subject_type, :string, public?: true)
    attribute(:scope_subject_id, :string, public?: true)

    attribute(:compensating_controls, {:array, :string}, default: [], public?: true)

    attribute(:replacement_rules_json, :string,
      public?: true,
      description: "For :replace overrides — the serialized replacement rule set JSON."
    )

    timestamps()
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([
        :organization_id,
        :kind,
        :rule_id,
        :reason,
        :approver,
        :approved_at,
        :starts_at,
        :expires_at,
        :scope_subject_type,
        :scope_subject_id,
        :compensating_controls,
        :replacement_rules_json
      ])

      validate({AshCompliance.Resources.PolicyOverride.ValidateOverride, []})
    end

    read :get_by_id do
      get_by([:id])
    end

    read :valid_for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      filter(
        expr(
          organization_id == ^arg(:organization_id) and
            (is_nil(starts_at) or starts_at <= ^arg(:now)) and
            (is_nil(expires_at) or expires_at > ^arg(:now))
        )
      )
    end
  end
end
