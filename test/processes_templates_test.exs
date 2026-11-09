# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ProcessesTemplatesTest do
  @moduledoc """
  Every shipped process and decision document compiles and verifies through the
  real engines, and the catalogue describing them is well formed.
  """

  use ExUnit.Case, async: true

  alias AshCompliance.Processes.{Decisions, Templates}

  @plan_rows 19

  # The compiler asks the invoker for its catalogue only when the export is
  # already loaded, so load it before any compile.
  setup_all do
    Code.ensure_loaded!(AshCompliance.Test.ActionInvoker)
    :ok
  end

  test "the catalogue lists every row of the plan's process table" do
    assert length(Templates.all()) == @plan_rows
    assert Templates.all() |> Enum.map(& &1.key) |> Enum.uniq() |> length() == @plan_rows
  end

  test "the catalogue has no faults" do
    assert Templates.faults() == []
  end

  describe "every BPMN template" do
    for template <- Templates.all() do
      @template template

      test "#{template.key} compiles through ash_bpmn" do
        assert {:ok, graph} = AshBpmn.Compiler.compile(Templates.xml(@template))
        assert graph["process_id"] == "Process_" <> @template.key
        assert graph["warnings"] == []
      end

      test "#{template.key} ends every refused or rejected path without evidence" do
        {:ok, graph} = AshBpmn.Compiler.compile(Templates.xml(@template))

        completions =
          for {_, %{"type" => "serviceTask", "action" => "compliance.record_completion"}} <-
                graph["nodes"],
              do: :completion

        assert completions == [:completion]
        end_outcomes = for {_, %{"type" => "endEvent"} = n} <- graph["nodes"], do: n["outcome"]
        assert "completed" in end_outcomes
      end

      test "#{template.key} gates every approval with the separation decision" do
        {:ok, graph} = AshBpmn.Compiler.compile(Templates.xml(@template))
        nodes = Map.values(graph["nodes"])
        approvals = Enum.filter(nodes, &(&1["type"] == "userTask" and approval?(&1)))
        checks = Enum.filter(nodes, &(&1["type"] == "businessRuleTask" and sod?(&1)))
        assert length(approvals) == length(checks)

        template = Templates.get(@template.key)
        if template.approval?, do: assert(approvals != [])

        for task <- approvals do
          assert Enum.any?(task["exclusions"], &(&1["who"] == "subject.requester_id"))
        end
      end
    end
  end

  describe "the shipped decisions" do
    for key <- Decisions.keys() do
      @key key

      test "#{key} compiles and verifies through ash_decisions" do
        assert {:ok, graph} = AshDecisions.Compiler.compile(Decisions.xml(@key))
        result = AshDecisions.Verifier.verify(graph)
        # Overlap under FIRST is legal and reported at :info; nothing stronger may remain.
        assert Enum.all?(result.findings, &(&1.severity == :info))
        assert Enum.all?(result.findings, &(&1.kind == :overlap))
      end
    end

    test "the separation decision has no obligations left undecided" do
      {:ok, graph} =
        AshDecisions.Compiler.compile(Decisions.xml("compliance.separation_of_duties"))

      result = AshDecisions.Verifier.verify(graph)
      assert result.obligations == []
    end
  end

  test "a template citing a decision the package does not ship does not compile" do
    xml =
      String.replace(
        Templates.xml("access_request"),
        "compliance.separation_of_duties",
        "compliance.not_shipped",
        global: true
      )

    assert {:error, errors} = AshBpmn.Compiler.compile(xml)
    assert Enum.any?(errors, &String.contains?(&1.message, "compliance.not_shipped"))
  end

  test "a template calling an action outside the catalogue does not compile" do
    xml =
      String.replace(
        Templates.xml("access_request"),
        "compliance.apply_decision",
        "compliance.nope"
      )

    assert {:error, errors} = AshBpmn.Compiler.compile(xml)
    assert Enum.any?(errors, &String.contains?(&1.message, "compliance.nope"))
  end

  defp approval?(task), do: task["exclusions"] not in [nil, []]
  defp sod?(node), do: get_in(node, ["decision", "ref"]) == "compliance.separation_of_duties"
end
