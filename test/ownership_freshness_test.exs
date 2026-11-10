# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipFreshnessTest do
  @moduledoc """
  The evaluator is pure. Every input it cannot positively establish comes out
  as `:unknown`, and none comes out as a pass.
  """

  use ExUnit.Case, async: true

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Ownership.{ControlFile, Freshness}

  @now ~U[2026-11-10 12:00:00Z]
  @producer "module:Producer"

  defp hours_ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  defp eval(row_overrides, artifacts) do
    Freshness.evaluate_row("CC6.1", row("CC6.1", row_overrides), artifacts, @now)
  end

  defp assert_unknown(result, reason) do
    assert %{state: :unknown, reason: ^reason} = result
    refute result.state in [:evidenced, :owned]
  end

  test "fresh evidence from the declared producer is evidenced" do
    result = eval(%{}, [artifact(@producer, hours_ago(3))])
    assert %{state: :evidenced, sources: [@producer]} = result
    assert result.latest_at == hours_ago(3)
  end

  test "no artifact at all is unknown" do
    assert_unknown(eval(%{}, []), :no_evidence)
  end

  test "an artifact older than the frequency allows is unknown" do
    assert_unknown(
      eval(%{"frequency" => "daily"}, [artifact(@producer, hours_ago(24 * 3))]),
      :stale
    )

    assert %{state: :evidenced} =
             eval(%{"frequency" => "daily"}, [artifact(@producer, hours_ago(24 * 2 - 1))])
  end

  test "a newer artifact rescues an older stale one, an older one cannot rescue a stale newest" do
    assert %{state: :evidenced} =
             eval(%{}, [
               artifact(@producer, hours_ago(24 * 30)),
               artifact(@producer, hours_ago(1))
             ])
  end

  test "a future-dated artifact is unknown" do
    future = DateTime.add(@now, 3600, :second)
    assert_unknown(eval(%{}, [artifact(@producer, future)]), :future_dated)
  end

  test "a future-dated artifact does not mask a stale one as fresh" do
    future = DateTime.add(@now, 86_400, :second)
    result = eval(%{}, [artifact(@producer, future), artifact(@producer, hours_ago(24 * 10))])
    assert_unknown(result, :stale)
  end

  test "a malformed timestamp is unknown" do
    for bad <- ["yesterday", "", nil, 12_345, "2026-13-45T00:00:00Z", %{}] do
      assert_unknown(eval(%{}, [artifact(@producer, bad)]), :malformed_timestamp)
    end
  end

  test "an ISO 8601 string timestamp is read" do
    assert %{state: :evidenced} =
             eval(%{}, [artifact(@producer, DateTime.to_iso8601(hours_ago(2)))])
  end

  test "an artifact with no valid hash is unknown" do
    for bad <- [
          nil,
          "",
          "abc",
          String.duplicate("g", 64),
          String.upcase(String.duplicate("a", 64))
        ] do
      assert_unknown(
        eval(%{}, [artifact(@producer, hours_ago(1), %{hash: bad})]),
        :malformed_artifact
      )
    end
  end

  test "an artifact from a producer the row does not declare is unknown" do
    assert_unknown(eval(%{}, [artifact("module:Other", hours_ago(1))]), :no_evidence)
  end

  test "an unknown frequency is unknown, even with fresh evidence" do
    for bad <- ["sometimes", nil, "", 7, "DAILY"] do
      assert_unknown(
        eval(%{"frequency" => bad}, [artifact(@producer, hours_ago(1))]),
        :unknown_frequency
      )
    end
  end

  test "an unknown class is unknown, even with fresh evidence" do
    for bad <- ["MAGIC", nil, "platform-enforced", 3] do
      assert_unknown(eval(%{"class" => bad}, [artifact(@producer, hours_ago(1))]), :unknown_class)
    end
  end

  test "an unknown applicability is unknown" do
    assert_unknown(
      eval(%{"applicability" => "maybe"}, [artifact(@producer, hours_ago(1))]),
      :invalid_applicability
    )
  end

  test "no owner role is unknown, even with fresh evidence" do
    assert_unknown(
      eval(%{"owner_role" => ""}, [artifact(@producer, hours_ago(1))]),
      :no_owner_role
    )
  end

  test "a row that is not an object is unknown" do
    for bad <- ["row", nil, 3, []] do
      assert_unknown(Freshness.evaluate_row("CC6.1", bad, [], @now), :malformed_row)
    end
  end

  test "a non-enforced row with no source is unknown; an enforced one is owned, not evidenced" do
    bare = %{"evidence_producer" => nil}
    assert_unknown(eval(Map.put(bare, "class", "ORG"), []), :no_source)
    assert %{state: :owned} = eval(Map.put(bare, "class", "PLATFORM-ENFORCED"), [])
  end

  test "a recurring process that did not run is overdue and the row is unknown" do
    overrides = %{
      "class" => "ORG",
      "frequency" => "quarterly",
      "operating_process" => "file:access-review.md"
    }

    only_producer = [artifact(@producer, hours_ago(1))]
    assert_unknown(eval(overrides, only_producer), :no_evidence)

    stale_process = only_producer ++ [artifact("file:access-review.md", hours_ago(24 * 200))]
    assert_unknown(eval(overrides, stale_process), :stale)

    ran = only_producer ++ [artifact("file:access-review.md", hours_ago(24 * 30))]

    assert %{state: :evidenced, sources: [@producer, "file:access-review.md"]} =
             eval(overrides, ran)
  end

  test "a VENDOR row needs a current vendor artifact" do
    vendor = %{"class" => "VENDOR", "vendor_ref" => "Hosting report", "frequency" => "annual"}
    assert_unknown(eval(vendor, [artifact(@producer, hours_ago(1))]), :no_evidence)

    assert %{state: :evidenced} =
             eval(vendor, [
               artifact(@producer, hours_ago(1)),
               artifact("Hosting report", hours_ago(24 * 100))
             ])
  end

  test "not_applicable needs a rationale" do
    assert %{state: :not_applicable} =
             eval(%{"applicability" => "not_applicable", "rationale" => "No premises"}, [])

    assert_unknown(eval(%{"applicability" => "not_applicable"}, []), :no_rationale)
  end

  describe "the control file" do
    test "missing" do
      [first | _] =
        results =
        Freshness.evaluate_all(ControlFile.load("/nonexistent/controls.json"), %{}, now: @now)

      assert length(results) == 33
      assert Enum.all?(results, &(&1.state == :unknown and &1.reason == :control_file_missing))
      assert first.criterion == "CC1.1"
    end

    test "malformed JSON" do
      results = Freshness.evaluate_all(ControlFile.parse("{ not json"), %{}, now: @now)
      assert Enum.all?(results, &(&1.state == :unknown and &1.reason == :control_file_malformed))
    end

    test "a criterion with no row, or two rows, is unknown" do
      rows = Enum.reject(rows(), &(&1["id"] == "CC7.1")) ++ [row("CC7.2")]
      results = Freshness.evaluate_all(loaded(rows), %{}, now: @now)
      by_id = Map.new(results, &{&1.criterion, &1})

      assert by_id["CC7.1"].reason == :no_row
      assert by_id["CC7.2"].reason == :duplicate_row
    end

    test "every other criterion with no evidence is unknown, never evidenced" do
      results = Freshness.evaluate_all(loaded(rows()), %{}, now: @now)
      assert Enum.all?(results, &(&1.state == :unknown))
    end
  end

  describe "overrides" do
    defp waiver(overrides) do
      Map.merge(
        %{
          kind: :waive,
          rule_id: Freshness.rule_id("CC6.1"),
          approver: "security-officer",
          reason: "documented",
          starts_at: hours_ago(1),
          expires_at: DateTime.add(@now, 3600, :second),
          scope_subject_type: nil,
          scope_subject_id: nil
        },
        overrides
      )
    end

    defp sweep(overrides) do
      loaded(rows())
      |> Freshness.evaluate_all(%{}, now: @now, overrides: overrides)
      |> Enum.find(&(&1.criterion == "CC6.1"))
    end

    test "an in-force waiver with approver and expiry silences, and the result stays unknown" do
      result = sweep([waiver(%{})])
      assert result.state == :unknown
      assert %{approver: "security-officer"} = result.silenced_by
    end

    test "an expired override does not silence" do
      assert sweep([waiver(%{expires_at: hours_ago(0)})]).silenced_by == nil
      assert sweep([waiver(%{expires_at: hours_ago(2)})]).silenced_by == nil
    end

    test "it stops silencing at the expiry instant" do
      expiry = DateTime.add(@now, 60, :second)
      override = waiver(%{expires_at: expiry})

      silenced = Freshness.evaluate_all(loaded(rows()), %{}, now: @now, overrides: [override])
      assert Enum.find(silenced, &(&1.criterion == "CC6.1")).silenced_by

      lapsed = Freshness.evaluate_all(loaded(rows()), %{}, now: expiry, overrides: [override])
      assert Enum.find(lapsed, &(&1.criterion == "CC6.1")).silenced_by == nil
    end

    test "an override with no approver does not silence" do
      for approver <- [nil, "", "   "] do
        assert sweep([waiver(%{approver: approver})]).silenced_by == nil
      end
    end

    test "an override with no expiry does not silence" do
      assert sweep([waiver(%{expires_at: nil})]).silenced_by == nil
    end

    test "a waiver longer than the maximum window does not silence" do
      far = DateTime.add(@now, 365 * 86_400, :second)
      assert sweep([waiver(%{expires_at: far})]).silenced_by == nil

      limit = DateTime.add(hours_ago(1), Freshness.max_waiver_seconds(), :second)
      assert sweep([waiver(%{expires_at: limit})]).silenced_by
      assert sweep([waiver(%{expires_at: DateTime.add(limit, 1, :second)})]).silenced_by == nil
    end

    test "a waiver whose start is unknown is measured from its approval, and with neither does not silence" do
      far = DateTime.add(@now, 365 * 86_400, :second)
      assert sweep([waiver(%{starts_at: nil, approved_at: hours_ago(1)})]).silenced_by

      assert sweep([waiver(%{starts_at: nil, approved_at: hours_ago(1), expires_at: far})]).silenced_by ==
               nil

      assert sweep([waiver(%{starts_at: nil})]).silenced_by == nil
      assert sweep([waiver(%{starts_at: "yesterday", approved_at: nil})]).silenced_by == nil
    end

    test "an override that has not started, for another rule, another kind or another scope does not silence" do
      assert sweep([waiver(%{starts_at: DateTime.add(@now, 60, :second)})]).silenced_by == nil
      assert sweep([waiver(%{rule_id: Freshness.rule_id("CC6.2")})]).silenced_by == nil
      assert sweep([waiver(%{kind: :replace})]).silenced_by == nil

      assert sweep([waiver(%{scope_subject_type: "account", scope_subject_id: "x"})]).silenced_by ==
               nil
    end

    test "an override never turns a non-unknown result into anything else" do
      row = rows() |> Enum.find(&(&1["id"] == "CC6.1"))

      results =
        Freshness.evaluate_all(loaded([row]), %{"CC6.1" => [artifact(@producer, hours_ago(1))]},
          now: @now,
          overrides: [waiver(%{})]
        )

      assert %{state: :evidenced, silenced_by: nil} =
               Enum.find(results, &(&1.criterion == "CC6.1"))
    end
  end
end
