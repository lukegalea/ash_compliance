# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.AccessReview.Seal do
  @moduledoc """
  The tamper seal on a recorded review decision.

  Decisions are append-only through the resource's action set, and a host can
  add a database trigger to make that physical. The seal covers the case where
  neither holds: every decision carries a hash over its own fields, and closing
  a campaign recomputes it. A decision edited in place no longer matches its
  hash, and the campaign refuses to close over it.
  """

  alias AshCompliance.Processes.Canonical

  @doc "The hash a decision with these fields must carry."
  @spec hash(map()) :: String.t()
  def hash(decision) do
    Canonical.sha256(%{
      "id" => field(decision, :id),
      "organization_id" => field(decision, :organization_id),
      "campaign_id" => field(decision, :campaign_id),
      "row_id" => field(decision, :row_id),
      "reviewer_id" => field(decision, :reviewer_id),
      "decision" => field(decision, :decision),
      "reason" => field(decision, :reason),
      "delegation_chain" => field(decision, :delegation_chain),
      "entitlement_digest" => field(decision, :entitlement_digest),
      "decided_at" => field(decision, :decided_at)
    })
  end

  @doc "True when the decision's stored hash matches its fields."
  @spec valid?(map()) :: boolean()
  def valid?(decision) do
    stored = field(decision, :record_hash)
    is_binary(stored) and stored == hash(decision)
  end

  defp field(%{} = decision, key), do: Map.get(decision, key)
end
