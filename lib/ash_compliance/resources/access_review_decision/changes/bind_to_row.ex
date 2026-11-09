# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewDecision.Changes.BindToRow do
  @moduledoc """
  Binds a decision to the row it is about.

  The row must exist and belong to the named campaign, and the campaign must be
  `:open`: nothing is decided on an incomplete or closed campaign. The
  organization, the delegation chain and the row's digest are taken from the
  records, never from the caller.
  """

  use Ash.Resource.Change

  alias AshCompliance.Domain

  @context_key :ash_compliance_review_target

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, &bind/1)
  end

  @doc false
  def context_key, do: @context_key

  defp bind(changeset) do
    campaign_id = Ash.Changeset.get_attribute(changeset, :campaign_id)
    row_id = Ash.Changeset.get_attribute(changeset, :row_id)

    with {:ok, campaign} <-
           fetch(campaign_id, &Domain.get_access_review_campaign_by_id/2, "campaign"),
         {:ok, row} <- fetch(row_id, &Domain.get_access_review_row_by_id/2, "row"),
         :ok <- same_campaign(row, campaign),
         :ok <- open(campaign) do
      changeset
      |> Ash.Changeset.force_change_attribute(:organization_id, campaign.organization_id)
      |> Ash.Changeset.force_change_attribute(:entitlement_digest, row.entitlement_digest)
      |> Ash.Changeset.force_change_attribute(
        :delegation_chain,
        Ash.Changeset.get_argument(changeset, :delegators) || []
      )
      |> Ash.Changeset.set_context(%{@context_key => %{campaign: campaign, row: row}})
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, message: message)
    end
  end

  defp fetch(nil, _fun, label), do: {:error, "#{label} is required"}

  defp fetch(id, fun, label) do
    case fun.(id, authorize?: false) do
      {:ok, record} when not is_nil(record) -> {:ok, record}
      _ -> {:error, "#{label} not found"}
    end
  end

  defp same_campaign(%{campaign_id: id}, %{id: id}), do: :ok
  defp same_campaign(_, _), do: {:error, "the row does not belong to this campaign"}

  defp open(%{status: :open}), do: :ok

  defp open(%{status: status}),
    do: {:error, "the campaign is #{status}, so nothing can be decided on it"}
end
