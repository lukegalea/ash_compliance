# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.Canonical do
  @moduledoc """
  Canonical JSON for hashing: object keys sorted, atoms and datetimes rendered
  as text, no insignificant whitespace.

  The same value always encodes to the same bytes whatever order its map keys
  were built in, which is what makes a content hash comparable later.
  """

  @doc "Canonical JSON text for `value`. Raises on a value JSON cannot hold."
  @spec encode!(term()) :: String.t()
  def encode!(value), do: value |> normalise() |> encode_term()

  @doc "Lower-case hex SHA-256 of the canonical JSON of `value`."
  @spec sha256(term()) :: String.t()
  def sha256(value), do: value |> encode!() |> AshCompliance.Ownership.Evidence.sha256()

  defp normalise(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp normalise(%Date{} = date), do: Date.to_iso8601(date)
  defp normalise(%Decimal{} = number), do: Decimal.to_string(number)
  defp normalise(nil), do: nil
  defp normalise(value) when is_boolean(value), do: value
  defp normalise(value) when is_atom(value), do: Atom.to_string(value)

  defp normalise(%_{} = struct),
    do: raise(ArgumentError, "cannot encode #{inspect(struct.__struct__)}")

  defp normalise(map) when is_map(map),
    do: {:object, map |> Enum.map(fn {k, v} -> {to_string(k), normalise(v)} end) |> Enum.sort()}

  defp normalise(list) when is_list(list), do: {:array, Enum.map(list, &normalise/1)}
  defp normalise(value) when is_binary(value) or is_number(value), do: value
  defp normalise(other), do: raise(ArgumentError, "cannot encode #{inspect(other)}")

  defp encode_term({:object, pairs}) do
    "{" <>
      Enum.map_join(pairs, ",", fn {k, v} -> Jason.encode!(k) <> ":" <> encode_term(v) end) <> "}"
  end

  defp encode_term({:array, items}), do: "[" <> Enum.map_join(items, ",", &encode_term/1) <> "]"
  defp encode_term(value), do: Jason.encode!(value)
end
