# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Json do
  @moduledoc """
  Canonical JSON for the generated files: object keys sorted, two-space
  indent, one trailing newline. Equal data always encodes to equal bytes.
  """

  @doc "Encodes a term built from maps, lists, strings, atoms, integers and booleans."
  @spec encode(term()) :: String.t()
  def encode(term), do: IO.iodata_to_binary([value(term, 0), "\n"])

  defp value(map, _depth) when is_map(map) and map_size(map) == 0, do: "{}"

  defp value(map, depth) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} ->
        [indent(depth + 1), Jason.encode!(k), ": ", value(v, depth + 1)]
      end)

    ["{\n", Enum.intersperse(pairs, ",\n"), "\n", indent(depth), "}"]
  end

  defp value([], _depth), do: "[]"

  defp value(list, depth) when is_list(list) do
    items = Enum.map(list, &[indent(depth + 1), value(&1, depth + 1)])
    ["[\n", Enum.intersperse(items, ",\n"), "\n", indent(depth), "]"]
  end

  defp value(nil, _), do: "null"
  defp value(b, _) when is_boolean(b), do: to_string(b)
  defp value(a, _) when is_atom(a), do: Jason.encode!(Atom.to_string(a))
  defp value(s, _) when is_binary(s), do: Jason.encode!(s)
  defp value(n, _) when is_integer(n), do: Integer.to_string(n)

  defp indent(depth), do: String.duplicate("  ", depth)
end
