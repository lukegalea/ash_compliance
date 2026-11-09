# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.AccessReviewCampaign.Changes.DeriveStatus do
  @moduledoc """
  Derives a new campaign's status from its sources; the caller cannot choose it.

  `:open` needs at least one declared source, no repeated source, and an `ok`
  result for every declared source and for no other. Anything else, including a
  missing result, an empty one, an errored one or a malformed one, is
  `:incomplete`.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      ids = Ash.Changeset.get_attribute(changeset, :source_ids) || []
      results = Ash.Changeset.get_attribute(changeset, :source_results) || %{}

      Ash.Changeset.force_change_attribute(changeset, :status, status(ids, results))
    end)
  end

  @doc false
  @spec status([String.t()], map()) :: :open | :incomplete
  def status(ids, results) do
    results = Map.new(results, fn {k, v} -> {to_string(k), v} end)

    complete? =
      ids != [] and ids == Enum.uniq(ids) and
        Enum.sort(ids) == results |> Map.keys() |> Enum.sort() and
        Enum.all?(ids, &(result_status(results, &1) == "ok"))

    if complete?, do: :open, else: :incomplete
  end

  @doc false
  @spec result_status(map(), String.t()) :: String.t() | nil
  def result_status(results, id) do
    case Map.get(results, id) do
      %{} = result -> result |> field(:status) |> to_string_or_nil()
      _ -> nil
    end
  end

  defp field(map, key), do: Map.get(map, Atom.to_string(key)) || Map.get(map, key)
  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
