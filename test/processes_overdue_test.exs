# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ProcessesOverdueTest do
  @moduledoc """
  An overdue process task raises a finding against the criteria its template
  supports. A source that cannot be read, or a task that cannot be read, is
  never a quiet pass.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.Domain
  alias AshCompliance.Processes.Overdue
  alias AshCompliance.Resources.Finding
  alias AshCompliance.TestRepo

  @now ~U[2026-11-10 12:00:00.000000Z]

  defmodule Source do
    @moduledoc false
    @behaviour AshCompliance.Processes.TaskSource

    @impl true
    def open_tasks(_org, opts), do: Keyword.fetch!(opts, :answer).()
  end

  setup do
    TestRepo.delete_all(Finding)
    %{org: Ecto.UUID.generate()}
  end

  defp sweep(org, answer) do
    Overdue.sweep(org, Source, now: @now, source_opts: [answer: fn -> answer end])
  end

  defp findings(org) do
    org
    |> Domain.findings_for_organization!(authorize?: false)
    |> Enum.filter(&(&1.subject_type == "process_overdue"))
  end

  defp task(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        process_key: "compliance.access_request",
        due_at: DateTime.add(@now, -3600, :second)
      },
      overrides
    )
  end

  test "an overdue task raises an unknown finding on every criterion of its template", %{org: org} do
    assert {:ok, [%{task_id: "t1"}]} = sweep(org, {:ok, [task("t1")]})

    found = findings(org)
    assert found |> Enum.map(& &1.control_id) |> Enum.sort() == ~w(CC6.1 CC6.2 CC6.3)

    for finding <- found do
      assert finding.status == :unknown
      assert finding.subject_id == "t1"
      assert finding.gap == "process_overdue"
      assert finding.resolved_at == nil
      assert finding.explanation =~ "overdue"
    end
  end

  test "a task that is not yet due raises nothing", %{org: org} do
    future = task("t1", %{due_at: DateTime.add(@now, 3600, :second)})
    assert {:ok, []} = sweep(org, {:ok, [future]})
    assert findings(org) == []
  end

  test "sweeping twice does not duplicate findings", %{org: org} do
    sweep(org, {:ok, [task("t1")]})
    sweep(org, {:ok, [task("t1")]})
    assert length(findings(org)) == 3
  end

  test "a task that closes resolves its finding without saying compliant", %{org: org} do
    sweep(org, {:ok, [task("t1")]})
    assert {:ok, []} = sweep(org, {:ok, []})

    for finding <- findings(org) do
      assert finding.resolved_at != nil
      assert finding.status == :unknown
    end
  end

  test "a task that stays overdue is not resolved while another closes", %{org: org} do
    sweep(org, {:ok, [task("t1"), task("t2", %{process_key: "compliance.break_glass"})]})
    sweep(org, {:ok, [task("t2", %{process_key: "compliance.break_glass"})]})

    by_subject = Enum.group_by(findings(org), & &1.subject_id)
    assert Enum.all?(by_subject["t1"], &(&1.resolved_at != nil))
    assert Enum.all?(by_subject["t2"], &(&1.resolved_at == nil))
  end

  describe "unknown is not a pass" do
    test "a task with a missing or malformed due time is overdue", %{org: org} do
      bad = [nil, "2026-01-01", 5, %{}]

      for {value, i} <- Enum.with_index(bad) do
        assert {:ok, [%{reason: "malformed_task"}]} =
                 sweep(org, {:ok, [task("bad-#{i}", %{due_at: value})]})
      end

      assert length(findings(org)) == 4 * 3
    end

    test "a task with no id is overdue and stays filed on the next sweep", %{org: org} do
      broken = %{process_key: "compliance.access_request", due_at: @now}
      assert {:ok, [_]} = sweep(org, {:ok, [broken]})
      assert {:ok, [_]} = sweep(org, {:ok, [broken]})
      assert Enum.all?(findings(org), &(&1.resolved_at == nil))
    end

    test "a task for a process no template defines is filed as unclassified", %{org: org} do
      assert {:ok, [%{controls: ["process:unclassified"]}]} =
               sweep(org, {:ok, [task("t1", %{process_key: "mystery"})]})

      assert [%{control_id: "process:unclassified", status: :unknown}] = findings(org)
    end

    test "a source that errors files a finding and resolves nothing", %{org: org} do
      sweep(org, {:ok, [task("t1")]})
      assert {:error, {:source_failed, :down}} = sweep(org, {:error, :down})

      found = findings(org)
      assert Enum.any?(found, &(&1.control_id == "process:task-source" and &1.resolved_at == nil))
      assert Enum.all?(found, &(&1.control_id == "process:task-source" or &1.resolved_at == nil))
    end

    test "a source that raises, or answers with something else, files a finding", %{org: org} do
      boom = fn -> raise "boom" end

      assert {:error, {:source_failed, {:raised, "boom"}}} =
               Overdue.sweep(org, Source, now: @now, source_opts: [answer: boom])

      assert {:error, {:source_failed, {:not_a_list, %{}}}} = sweep(org, {:ok, %{}})
      assert {:error, {:source_failed, {:unexpected_return, :nothing}}} = sweep(org, :nothing)
      assert [%{control_id: "process:task-source", status: :unknown}] = findings(org)
    end

    test "the source failure finding resolves once the source reads again", %{org: org} do
      sweep(org, {:error, :down})
      assert {:ok, []} = sweep(org, {:ok, []})
      assert [%{control_id: "process:task-source", resolved_at: %DateTime{}}] = findings(org)
    end
  end
end
