# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.RuleSetRevision.Validations.LayerInScheme do
  @moduledoc """
  A revision's `layer` must be a layer of its `scheme`.

  With no `scheme` (every revision the default compile reads) the layers are
  the six default ranks, `AshCompliance.Compiler.Layer.layers/0`, as they
  have always been. A revision recorded under a declared scheme names the
  `AshCompliance.Layering` module (as `inspect/1` spells it) and may sit at
  any layer that scheme declares. The scheme must already be a loaded
  module: its name is never turned into a new atom.

  Temporal-safe: reads two attributes, no clock, no side effects.
  """

  use Ash.Resource.Validation

  alias AshCompliance.Compiler.Layer
  alias AshCompliance.Layering

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def validate(changeset, _opts, _context) do
    layer = Ash.Changeset.get_attribute(changeset, :layer)
    scheme = Ash.Changeset.get_attribute(changeset, :scheme)

    with {:ok, layers} <- layers(scheme) do
      cond do
        is_nil(layer) -> :ok
        layer in layers -> :ok
        true -> {:error, field: :layer, message: "must be one of #{Enum.join(layers, ", ")}"}
      end
    end
  end

  defp layers(nil), do: {:ok, Layer.layers()}

  defp layers(scheme) when is_binary(scheme) do
    module = String.to_existing_atom("Elixir." <> scheme)

    if Code.ensure_loaded?(module) and function_exported?(module, :layers, 0),
      do: {:ok, Layering.layers(module)},
      else: unknown(scheme)
  rescue
    ArgumentError -> unknown(scheme)
  end

  defp unknown(scheme),
    do:
      {:error, field: :scheme, message: "#{scheme} is not a loaded AshCompliance.Layering module"}
end
