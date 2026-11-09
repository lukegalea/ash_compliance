# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewCampaign do
  @moduledoc """
  One review of effective access, from the sources it was opened against to the
  sign-off that closes it.

  `source_results` records what each declared source answered
  (`ok`, `empty`, `errored` or `malformed`). The status is derived from it and
  cannot be set: a campaign is `:open` only when every declared source answered
  with entries, and `:incomplete` otherwise. An incomplete campaign cannot be
  closed, so a source that failed or listed nobody never turns into a review
  that passed.

  Closing needs every row decided, every decision's seal intact, and a recorded
  sign-off by someone other than the person who opened the campaign. See
  `AshCompliance.AccessReview`.
  """

  use AshCompliance.Resource, table: "access_review_campaigns"

  alias AshCompliance.Resources.AccessReviewCampaign.Changes

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)

    attribute(:name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1]
    )

    attribute(:period, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1],
      description: "The review period, for example 2026-Q4."
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :incomplete,
      public?: true,
      constraints: [one_of: [:open, :incomplete, :closed]]
    )

    attribute(:source_ids, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:source_results, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:opened_by, :string, allow_nil?: false, public?: true)
    attribute(:opened_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:closed_by, :string, public?: true)
    attribute(:closed_at, :utc_datetime_usec, public?: true)
    attribute(:close_summary, :map, public?: true)

    create_timestamp(:inserted_at)
  end

  actions do
    defaults([:read])

    create :open do
      primary?(true)

      accept([
        :organization_id,
        :name,
        :period,
        :source_ids,
        :source_results,
        :opened_by,
        :opened_at
      ])

      change(Changes.DeriveStatus)
    end

    update :close do
      require_atomic?(false)
      accept([])

      argument(:closed_by, :string, allow_nil?: false, constraints: [min_length: 1])
      argument(:delegators, {:array, :string}, allow_nil?: false, default: [])

      change(Changes.RequireComplete)
    end

    read :for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end
  end
end
