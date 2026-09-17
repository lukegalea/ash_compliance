# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Oscal.ProfileOperation do
  @moduledoc """
  Validation and normalization of profile-revision tailoring operations.

  Operations are stored as data (plain maps), but not as *arbitrary* data:
  every operation must carry a known `op` and the fields that op requires.
  Both string-keyed (JSON-decoded) and atom-keyed maps are accepted; the
  normalized form uses atom keys.

  `replace` and `waive` are approval-bearing operations and are refused on
  profile revisions — they belong in
  `AshCompliance.Resources.PolicyOverride`, where approver, compensating
  controls and time bounds are enforced.
  """

  @ops [:include, :exclude, :parameterize, :refine, :supplement]
  @refused_ops [:replace, :waive]

  @doc "The operations a profile revision may declare."
  @spec ops() :: [atom(), ...]
  def ops, do: @ops

  @doc "The operations that are refused on profile revisions (approval-bearing)."
  @spec refused_ops() :: [atom(), ...]
  def refused_ops, do: @refused_ops

  @doc "Normalizes one operation map. Returns `{:ok, op}` or `{:error, message}`."
  @spec normalize(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize(%{"op" => op} = operation) when is_binary(op),
    do: do_normalize(atomize_op(op), operation)

  def normalize(%{op: op} = operation) when is_binary(op),
    do: do_normalize(atomize_op(op), operation)

  def normalize(%{op: op} = operation), do: do_normalize(op, operation)

  def normalize(_),
    do: {:error, "a profile operation must be a map with an op key"}

  defp do_normalize(op, operation) when op in @ops do
    target = fetch(operation, :target)

    if blank?(target) do
      {:error, "profile operation #{op} requires a target (a rule or control id)"}
    else
      {:ok,
       %{
         op: op,
         target: target,
         severity: atomize(fetch(operation, :severity)),
         message: fetch(operation, :message),
         params: fetch(operation, :params) || %{},
         text: fetch(operation, :text)
       }
       |> Map.reject(fn {_key, value} -> is_nil(value) end)}
    end
  end

  defp do_normalize(op, _operation) when op in @refused_ops do
    {:error,
     "#{op} is an approval-bearing operation. Record it in " <>
       "AshCompliance.Resources.PolicyOverride with approver, compensating " <>
       "controls and time bounds - a profile revision cannot carry it"}
  end

  defp do_normalize(op, _operation),
    do: {:error, "unknown profile operation #{inspect(op)}"}

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp atomize_op(op) do
    String.to_existing_atom(op)
  rescue
    ArgumentError -> op
  end

  defp atomize(nil), do: nil

  defp atomize(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp atomize(value), do: value

  defp blank?(value), do: value in [nil, ""]
end
