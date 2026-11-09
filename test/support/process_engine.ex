# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.DecisionResolver do
  @moduledoc false
  # Answers the publish-time question "does this decision exist" from the
  # decisions this package ships, and evaluates them through the real engine.

  @behaviour AshBpmn.DecisionResolver

  alias AshCompliance.Processes.Decisions

  @impl true
  def exists?(ref), do: Decisions.exists?(ref)

  @impl true
  def decide(ref, inputs, _context) do
    case AshDecisions.Evaluator.evaluate(Decisions.definition(ref), inputs,
           decision: Decisions.decision_name(ref),
           record: false
         ) do
      {:ok, %{outputs: outputs}} -> {:ok, %{outputs: outputs}}
      {:error, _} = error -> error
    end
  end
end

defmodule AshCompliance.Test.ActionInvoker do
  @moduledoc false
  # The publish-time catalogue of service-task actions the templates call.

  @behaviour AshBpmn.ActionInvoker

  def exists?(ref), do: ref in AshCompliance.Processes.Templates.actions()

  @impl true
  def invoke(_action, _ctx), do: {:ok, %{}}
end
