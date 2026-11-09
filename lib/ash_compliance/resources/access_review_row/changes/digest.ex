# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewRow.Changes.Digest do
  @moduledoc """
  Computes a row's `entitlement_digest` from its entitlements. The digest is
  never accepted from the caller.
  """

  use Ash.Resource.Change

  alias AshCompliance.AccessReview.Merge

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      entitlements = Ash.Changeset.get_attribute(changeset, :entitlements) || %{}

      Ash.Changeset.force_change_attribute(
        changeset,
        :entitlement_digest,
        Merge.digest(entitlements)
      )
    end)
  end
end
