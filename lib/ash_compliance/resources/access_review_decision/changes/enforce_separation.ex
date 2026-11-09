# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewDecision.Changes.EnforceSeparation do
  @moduledoc """
  A reviewer may not decide on their own access, nor on the access of someone
  they are acting for. The person under review is the requester and the
  reviewer is the approver, asked of the shipped separation decision.
  """

  use Ash.Resource.Change

  alias AshCompliance.Processes.Gate
  alias AshCompliance.Resources.AccessReviewDecision.Changes.BindToRow

  @process_key "compliance.effective_access_review"

  @impl true
  def change(changeset, _opts, _context), do: Gate.attach(changeset, &resolve/1)

  defp resolve(changeset) do
    case changeset.context[BindToRow.context_key()] do
      %{campaign: campaign, row: row} ->
        {:ok, campaign.organization_id,
         %{
           process_key: @process_key,
           subject_id: row.id,
           requester_id: row.person_key,
           approver_id: Ash.Changeset.get_attribute(changeset, :reviewer_id),
           delegators: Ash.Changeset.get_argument(changeset, :delegators)
         }}

      _ ->
        {:error, "the decision is not bound to a row"}
    end
  end
end
