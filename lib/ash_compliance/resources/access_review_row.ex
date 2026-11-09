# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewRow do
  @moduledoc """
  One person's effective access in a campaign: every grant every source gave
  them, merged. There is exactly one row per person per campaign.

  `entitlement_digest` is computed from `entitlements` when the row is created,
  and each decision records the digest of the row it was made against, so a row
  edited after review no longer matches the decisions made on it.

  Create and read only.
  """

  use AshCompliance.Resource, table: "access_review_rows"

  alias AshCompliance.Resources.AccessReviewRow.Changes

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)
    attribute(:person_key, :string, allow_nil?: false, public?: true)
    attribute(:sources, {:array, :string}, allow_nil?: false, default: [], public?: true)

    attribute(:entitlements, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      description: "Source id to the list of grants that source gave this person."
    )

    attribute(:entitlement_digest, :string, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :campaign, AshCompliance.Resources.AccessReviewCampaign do
      allow_nil?(false)
      public?(true)
    end
  end

  identities do
    identity(:one_row_per_person, [:campaign_id, :person_key])
  end

  actions do
    defaults([:read])

    create :add do
      primary?(true)
      accept([:organization_id, :campaign_id, :person_key, :sources, :entitlements])

      change(Changes.Digest)
    end

    read :for_campaign do
      argument(:campaign_id, :uuid, allow_nil?: false)
      filter(expr(campaign_id == ^arg(:campaign_id)))
    end
  end
end
