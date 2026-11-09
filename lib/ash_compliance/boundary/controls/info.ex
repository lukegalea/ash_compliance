# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Controls.Info do
  @moduledoc "Introspection for the `controls` section of a declaration."

  alias Spark.Dsl.Extension

  @doc """
  The controls and the production facts they read, as one plain map, entities
  sorted by their identifier.
  """
  @spec declaration(module()) :: map()
  def declaration(module) do
    module
    |> AshCompliance.Boundary.Info.declaration()
    |> Map.put(:audited_environments, audited_environments(module))
    |> Map.put(:controls, sort_by(controls(module), & &1.criterion))
  end

  @spec audited_environments(module()) :: [atom()] | nil
  def audited_environments(module),
    do: Extension.get_opt(module, [:controls], :audited_environments, nil)

  @spec controls(module()) :: [AshCompliance.Boundary.Controls.Control.t()]
  def controls(module), do: Extension.get_entities(module, [:controls])

  defp sort_by(list, fun), do: Enum.sort_by(list, &to_string(fun.(&1)))
end
