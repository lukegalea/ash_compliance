# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewDecision do
  @moduledoc """
  A reviewer's decision about one person's effective access: keep it or revoke
  it.

  Create and read only. A reviewer who changes their mind records a new
  decision; the latest decision for a row is the effective one and every earlier
  one stays on record. The resource has no update or destroy action, and each
  decision carries a seal (`record_hash`) over its own fields that closing the
  campaign verifies.

  A reviewer cannot decide on their own access, or on the access of someone they
  are acting for. The separation-of-duties decision is asked before anything is
  written, a refusal is rejected with an error, and the refused attempt is
  recorded as an `AshCompliance.Resources.ApprovalAttempt`.
  """

  use AshCompliance.Resource, table: "access_review_decisions"

  alias AshCompliance.Resources.AccessReviewDecision.Changes

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)
    attribute(:reviewer_id, :string, allow_nil?: false, public?: true)

    attribute(:decision, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:keep, :revoke]]
    )

    attribute(:reason, :string, public?: true)
    attribute(:delegation_chain, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:entitlement_digest, :string, allow_nil?: false, public?: true)
    attribute(:decided_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:record_hash, :string, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :campaign, AshCompliance.Resources.AccessReviewCampaign do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :row, AshCompliance.Resources.AccessReviewRow do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :record do
      primary?(true)
      accept([:campaign_id, :row_id, :reviewer_id, :decision, :reason])

      argument(:delegators, {:array, :string}, allow_nil?: false, default: [])

      validate(present(:reviewer_id))

      change(Changes.BindToRow)
      change(Changes.EnforceSeparation)
      change(Changes.Seal)
    end

    read :for_campaign do
      argument(:campaign_id, :uuid, allow_nil?: false)
      filter(expr(campaign_id == ^arg(:campaign_id)))
    end
  end
end
