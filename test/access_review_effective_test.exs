# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.AccessReviewEffectiveTest do
  @moduledoc """
  The standing decision for a row is the chronologically latest, whatever the
  day, hour or microsecond fields happen to compare as.
  """

  use ExUnit.Case, async: true

  alias AshCompliance.AccessReview.Effective

  defp decision(row, id, decision, at),
    do: %{row_id: row, id: id, decision: decision, decided_at: at}

  defp standing(decisions), do: Effective.latest_per_row(decisions)["r1"].decision

  test "a later month wins although its day number is smaller" do
    assert :revoke ==
             standing([
               decision("r1", "a", :keep, ~U[2026-10-30 10:00:00.000000Z]),
               decision("r1", "b", :revoke, ~U[2026-11-02 10:00:00.000000Z])
             ])
  end

  test "a later minute wins although its microsecond field is smaller" do
    assert :revoke ==
             standing([
               decision("r1", "a", :keep, ~U[2026-11-02 10:05:00.900000Z]),
               decision("r1", "b", :revoke, ~U[2026-11-02 10:06:00.100000Z])
             ])
  end

  test "input order does not matter" do
    ds = [
      decision("r1", "a", :keep, ~U[2026-10-30 10:00:00.000000Z]),
      decision("r1", "b", :revoke, ~U[2026-11-02 10:00:00.000000Z])
    ]

    assert standing(ds) == standing(Enum.reverse(ds))
  end

  test "rows are decided independently" do
    result =
      Effective.latest_per_row([
        decision("r1", "a", :keep, ~U[2026-11-02 10:00:00.000000Z]),
        decision("r2", "b", :revoke, ~U[2026-10-30 10:00:00.000000Z])
      ])

    assert %{"r1" => %{decision: :keep}, "r2" => %{decision: :revoke}} = result
  end
end
