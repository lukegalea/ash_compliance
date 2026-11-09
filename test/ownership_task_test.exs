# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipTaskTest do
  # Mix.shell is global.
  use ExUnit.Case, async: false

  import AshCompliance.Test.OwnershipFixtures

  alias Mix.Tasks.AshCompliance.Controls.Check, as: Task

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp output do
    receive do
      {:mix_shell, :info, [line]} -> [line | output()]
    after
      0 -> []
    end
  end

  defp complete_file do
    # Rows reference this repo's own files so the real resolver passes.
    rows =
      rows(
        [:security],
        %{
          "evidence_producer" => "module:AshCompliance.Ownership.Evidence",
          "test_ref" => "file:mix.exs"
        }
      )

    tmp_file("controls.json", Jason.encode!(%{"criteria" => rows}))
  end

  test "a complete file passes" do
    Task.run(["--file", complete_file()])
    assert Enum.join(output()) =~ "no problems across 33 criteria"
  end

  test "a missing criterion fails the task and names the row" do
    path = tmp_file("controls.json", Jason.encode!(%{"criteria" => [row("CC1.1")]}))

    assert_raise Mix.Error, ~r/problem/, fn -> Task.run(["--file", path]) end
    assert Enum.any?(output(), &(&1 =~ "CC6.1" and &1 =~ "missing_criterion"))
  end

  test "--report lists every problem and does not fail" do
    path = tmp_file("controls.json", Jason.encode!(%{"criteria" => [row("CC1.1")]}))

    assert Task.run(["--file", path, "--report"]) == nil
    lines = output()
    assert Enum.count(lines, &(&1 =~ "missing_criterion")) == 32
  end

  test "--report on a missing file still lists the problem and does not fail" do
    Task.run(["--file", "/nonexistent/controls.json", "--report"])
    assert Enum.any?(output(), &(&1 =~ "control_file"))
  end

  test "a missing file fails without --report" do
    assert_raise Mix.Error, fn -> Task.run(["--file", "/nonexistent/controls.json"]) end
  end

  test "--categories widens the audit" do
    assert_raise Mix.Error, fn ->
      Task.run(["--file", complete_file(), "--categories", "security,availability"])
    end

    assert Enum.count(output(), &(&1 =~ "missing_criterion")) == 3
  end

  test "an unknown category is refused" do
    assert_raise Mix.Error, ~r/unknown category/, fn ->
      Task.run(["--file", complete_file(), "--categories", "everything"])
    end
  end
end
