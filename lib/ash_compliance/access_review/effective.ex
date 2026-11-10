# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.AccessReview.Effective do
  @moduledoc """
  Which decision stands for a row. A changed mind is a new decision and the
  earlier one stays, so the latest by `decided_at` is the one that counts.
  Instants are compared as microseconds: `DateTime` structs compare field by
  field under term order, which is not chronological.
  """

  @doc "The standing decision for each row id."
  def latest_per_row(decisions) do
    decisions
    |> Enum.group_by(& &1.row_id)
    |> Map.new(fn {row_id, list} ->
      {row_id, Enum.max_by(list, &{DateTime.to_unix(&1.decided_at, :microsecond), &1.id})}
    end)
  end
end
