# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewCampaign.Changes.RequireComplete do
  @moduledoc """
  Refuses to close a campaign that is not demonstrably complete, and records the
  sign-off.

  A campaign closes only when all of these hold:

    * it is `:open`, so every declared source answered with entries
    * it has at least one row
    * every row has at least one decision
    * every decision still matches its seal, and the digest of the row it was
      made against, and every row still matches its own digest
    * the person closing it is not the person who opened it, nor anyone that
      person is acting for (the sign-off passes through the separation decision)

  Anything else is an error that names what failed. The summary stored on the
  campaign records counts and a digest of the decision seals, so the closed
  campaign says what was decided and not merely that it was closed.
  """

  use Ash.Resource.Change

  alias AshCompliance.AccessReview.{Merge, Seal}
  alias AshCompliance.Domain
  alias AshCompliance.Processes.{Canonical, Gate}
  alias AshCompliance.Resources.AccessReviewCampaign.Changes.DeriveStatus

  @process_key "compliance.effective_access_review"

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&check/1)
    |> Gate.attach(&resolve/1)
  end

  defp resolve(changeset) do
    campaign = changeset.data

    {:ok, campaign.organization_id,
     %{
       process_key: @process_key,
       subject_id: campaign.id,
       requester_id: campaign.opened_by,
       approver_id: Ash.Changeset.get_argument(changeset, :closed_by),
       delegators: Ash.Changeset.get_argument(changeset, :delegators)
     }}
  end

  defp check(changeset) do
    campaign = changeset.data

    with :ok <- open(campaign),
         {:ok, rows} <- Domain.access_review_rows_for_campaign(campaign.id, authorize?: false),
         {:ok, decisions} <-
           Domain.access_review_decisions_for_campaign(campaign.id, authorize?: false),
         :ok <- rows_present(rows),
         :ok <- rows_intact(rows),
         :ok <- decisions_intact(decisions, rows),
         :ok <- all_decided(rows, decisions) do
      closed_by = Ash.Changeset.get_argument(changeset, :closed_by)

      changeset
      |> Ash.Changeset.force_change_attribute(:status, :closed)
      |> Ash.Changeset.force_change_attribute(:closed_by, closed_by)
      |> Ash.Changeset.force_change_attribute(:closed_at, DateTime.utc_now())
      |> Ash.Changeset.force_change_attribute(:close_summary, summary(campaign, rows, decisions))
    else
      {:error, message} when is_binary(message) ->
        Ash.Changeset.add_error(changeset, message: message)

      {:error, other} ->
        Ash.Changeset.add_error(changeset,
          message: "the campaign could not be checked: " <> inspect(other, limit: 5)
        )
    end
  end

  defp open(%{status: :open}), do: :ok
  defp open(%{status: :closed}), do: {:error, "the campaign is already closed"}

  defp open(%{status: :incomplete} = campaign) do
    {:error, "the campaign is incomplete: " <> incomplete_detail(campaign)}
  end

  defp incomplete_detail(%{source_ids: ids, source_results: results}) do
    results = Map.new(results || %{}, fn {k, v} -> {to_string(k), v} end)

    problems =
      for id <- ids || [], DeriveStatus.result_status(results, id) != "ok" do
        "#{id} #{DeriveStatus.result_status(results, id) || "gave no result"}"
      end

    case {ids, problems} do
      {ids, _} when ids in [nil, []] -> "no sources were declared"
      {_, []} -> "its sources do not match its results"
      {_, problems} -> Enum.join(problems, ", ")
    end
  end

  defp rows_present([]), do: {:error, "the campaign has no rows to review"}
  defp rows_present(_), do: :ok

  defp rows_intact(rows) do
    case Enum.filter(rows, &(Merge.digest(&1.entitlements) != &1.entitlement_digest)) do
      [] -> :ok
      changed -> {:error, "#{length(changed)} row(s) changed after they were created"}
    end
  end

  defp decisions_intact(decisions, rows) do
    digests = Map.new(rows, &{&1.id, &1.entitlement_digest})

    cond do
      (bad = Enum.reject(decisions, &Seal.valid?/1)) != [] ->
        {:error, "#{length(bad)} decision(s) fail their seal and were altered after recording"}

      (stale = Enum.reject(decisions, &(Map.get(digests, &1.row_id) == &1.entitlement_digest))) !=
          [] ->
        {:error, "#{length(stale)} decision(s) do not match the row they were made on"}

      true ->
        :ok
    end
  end

  defp all_decided(rows, decisions) do
    decided = MapSet.new(decisions, & &1.row_id)

    case Enum.reject(rows, &MapSet.member?(decided, &1.id)) do
      [] -> :ok
      undecided -> {:error, "#{length(undecided)} row(s) have no decision"}
    end
  end

  defp summary(campaign, rows, decisions) do
    effective =
      decisions
      |> Enum.group_by(& &1.row_id)
      |> Map.new(fn {row_id, list} -> {row_id, Enum.max_by(list, &{&1.decided_at, &1.id})} end)

    counts = effective |> Map.values() |> Enum.frequencies_by(& &1.decision)

    %{
      "rows" => length(rows),
      "decisions" => length(decisions),
      "keep" => Map.get(counts, :keep, 0),
      "revoke" => Map.get(counts, :revoke, 0),
      "seal_digest" =>
        decisions |> Enum.map(& &1.record_hash) |> Enum.sort() |> Canonical.sha256(),
      "sources" => campaign.source_results
    }
  end
end
