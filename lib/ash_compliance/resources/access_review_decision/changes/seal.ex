# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewDecision.Changes.Seal do
  @moduledoc """
  Stamps the decision time and seals the record. Neither is accepted from the
  caller.
  """

  use Ash.Resource.Change

  alias AshCompliance.AccessReview.Seal

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &seal/1)
  end

  defp seal(changeset) do
    changeset =
      Ash.Changeset.force_change_attribute(changeset, :decided_at, DateTime.utc_now())

    attrs =
      [
        :id,
        :organization_id,
        :campaign_id,
        :row_id,
        :reviewer_id,
        :decision,
        :reason,
        :delegation_chain,
        :entitlement_digest,
        :decided_at
      ]
      |> Map.new(&{&1, Ash.Changeset.get_attribute(changeset, &1)})

    Ash.Changeset.force_change_attribute(changeset, :record_hash, Seal.hash(attrs))
  end
end
