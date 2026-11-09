# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.SeparationOfDuties do
  @moduledoc """
  Asks the shipped `compliance.separation_of_duties` decision whether an
  approver may approve a requester's request.

  The decision answers; this module carries the answer to the caller and fails
  closed. Anything that is not an explicit `permit` from the decision is a
  refusal: a missing requester or approver, an unrecorded delegation chain, an
  engine that is not installed, a model that will not load, an evaluation that
  errors or times out, and an answer in a shape this module does not recognise.

  `delegators` is the chain of people the approver is acting for. It must be a
  list; an empty list means "acting for nobody" and `nil` means the chain was
  not recorded, which is refused. Principals are compared as trimmed,
  lower-cased text, so two spellings of one identifier count as one person. A requester anywhere in the chain is a
  refusal, so approving through a delegation from the requester is the same as
  approving your own request.

  The engine is `ash_decisions`, an optional dependency. Without it every check
  is refused with `:engine_unavailable`.
  """

  alias AshCompliance.Processes.Decisions

  @key "compliance.separation_of_duties"

  @compile {:no_warn_undefined, [AshDecisions.Evaluator]}

  @type verdict :: %{
          outcome: :permit | :refuse,
          reason: String.t(),
          decision_hash: String.t()
        }

  @doc "The decision reference."
  @spec decision_key() :: String.t()
  def decision_key, do: @key

  @doc """
  Evaluates the decision. Always returns a verdict; `outcome` is `:permit` only
  when the decision said `permit` and nothing about the inputs was unknown.
  """
  @spec check(term(), term(), term()) :: verdict()
  def check(requester, approver, delegators) do
    hash = Decisions.content_hash(@key)

    case normalise(requester, approver, delegators) do
      {:ok, inputs} -> evaluate(inputs, hash)
      {:error, reason} -> refuse(reason, hash)
    end
  end

  @doc "True when the verdict permits."
  @spec permit?(verdict()) :: boolean()
  def permit?(%{outcome: :permit}), do: true
  def permit?(_), do: false

  defp normalise(requester, approver, delegators) do
    with {:ok, requester} <- principal(requester, "requester_unknown"),
         {:ok, approver} <- principal(approver, "approver_unknown"),
         {:ok, delegators} <- chain(delegators) do
      {:ok, %{"requester" => requester, "approver" => approver, "delegators" => delegators}}
    end
  end

  defp principal(value, reason) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, reason}
      trimmed -> {:ok, String.downcase(trimmed)}
    end
  end

  defp principal(_, reason), do: {:error, reason}

  defp chain(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, Enum.map(list, &(&1 |> String.trim() |> String.downcase()))},
      else: {:error, "delegation_unknown"}
  end

  defp chain(_), do: {:error, "delegation_unknown"}

  defp evaluate(inputs, hash) do
    if Code.ensure_loaded?(AshDecisions.Evaluator) do
      definition = Decisions.definition(@key)

      case AshDecisions.Evaluator.evaluate(definition, inputs,
             decision: Decisions.decision_name(@key),
             record: false
           ) do
        {:ok, %{outputs: outputs}} -> interpret(outputs, hash)
        {:error, _} -> refuse("decision_error", hash)
      end
    else
      refuse("engine_unavailable", hash)
    end
  rescue
    _ -> refuse("decision_error", hash)
  catch
    _, _ -> refuse("decision_error", hash)
  end

  @doc false
  @spec interpret(term(), String.t()) :: verdict()
  def interpret(%{"outcome" => "permit", "reason" => reason}, hash) when is_binary(reason),
    do: %{outcome: :permit, reason: reason, decision_hash: hash}

  def interpret(%{"outcome" => "refuse", "reason" => reason}, hash) when is_binary(reason),
    do: refuse(reason, hash)

  def interpret(_other, hash), do: refuse("unrecognised_answer", hash)

  defp refuse(reason, hash), do: %{outcome: :refuse, reason: reason, decision_hash: hash}
end
