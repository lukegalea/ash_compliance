# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.WaiverChainTest do
  @moduledoc """
  The 90-day limit is per approval chain, not per row. Windows only have to not overlap, and a
  waiver may be future-dated, so one caller could otherwise write back-to-back waivers in one
  sitting and keep a criterion silenced for years. A waiver that starts where the previous one
  for the same organization, rule and scope ended (within the renewal gap) continues its chain,
  and the whole chain may not run past `Freshness.max_waiver_seconds/0`. Renewing means letting
  the waiver lapse for at least `Freshness.renewal_gap_seconds/0`, which files a finding.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.Ownership.Freshness

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)
  @day 86_400

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  defp waive(org, starts, expires, extra \\ %{}) do
    AshCompliance.Domain.create_policy_override(
      Map.merge(
        %{
          organization_id: org,
          kind: :waive,
          rule_id: Freshness.rule_id("CC6.1"),
          reason: "documented operational exception",
          approver: "b",
          requested_by: "a",
          approved_at: @now,
          starts_at: starts,
          expires_at: expires,
          compensating_controls: ["x"]
        },
        extra
      ),
      authorize?: false
    )
  end

  test "control: one waiver of the maximum length is accepted" do
    org = Ecto.UUID.generate()
    assert {:ok, _} = waive(org, @now, at(Freshness.max_waiver_seconds()))
  end

  test "back-to-back waivers cannot extend a chain past the maximum" do
    org = Ecto.UUID.generate()
    max = Freshness.max_waiver_seconds()

    assert {:ok, _} = waive(org, @now, at(max))
    assert {:error, _} = waive(org, at(max), at(2 * max))
    assert {:error, _} = waive(org, at(max + 3600), at(max + 3600 + 3600))
  end

  test "a chain of short waivers is bounded as a whole" do
    org = Ecto.UUID.generate()
    max = Freshness.max_waiver_seconds()
    step = 30 * @day

    assert {:ok, _} = waive(org, @now, at(step))
    assert {:ok, _} = waive(org, at(step), at(2 * step))
    assert {:ok, _} = waive(org, at(2 * step), at(3 * step))
    assert 3 * step == max
    assert {:error, _} = waive(org, at(3 * step), at(4 * step))
  end

  test "renewal after a lapse of the renewal gap starts a new chain" do
    org = Ecto.UUID.generate()
    max = Freshness.max_waiver_seconds()
    gap = Freshness.renewal_gap_seconds()

    assert {:ok, _} = waive(org, @now, at(max))
    assert {:error, _} = waive(org, at(max + gap - 1), at(max + gap + 3600))
    assert {:ok, _} = waive(org, at(max + gap), at(max + gap + max))
  end

  test "another rule, another scope or another organization has its own chain" do
    org = Ecto.UUID.generate()
    max = Freshness.max_waiver_seconds()
    assert {:ok, _} = waive(org, @now, at(max))

    assert {:ok, _} =
             waive(org, at(max), at(2 * max), %{rule_id: Freshness.rule_id("CC6.2")})

    assert {:ok, _} =
             waive(org, at(max), at(2 * max), %{
               scope_subject_type: "freshness_criterion",
               scope_subject_id: "CC6.1"
             })

    assert {:ok, _} = waive(Ecto.UUID.generate(), at(max), at(2 * max))
  end
end
