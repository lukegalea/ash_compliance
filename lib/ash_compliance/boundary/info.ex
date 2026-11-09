# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Info do
  @moduledoc "Introspection for modules that `use AshCompliance.Boundary.Declaration`."

  alias Spark.Dsl.Extension

  @doc "The declaration as one plain map, entities sorted by their identifier."
  @spec declaration(module()) :: map()
  def declaration(module) do
    %{
      name: name(module),
      output_dir: output_dir(module),
      environments: sort_by(environments(module), & &1.name),
      resources: sort_by(resources(module), & &1.name),
      controls: sort_by(controls(module), & &1.criterion)
    }
  end

  @spec name(module()) :: String.t() | nil
  def name(module), do: Extension.get_opt(module, [:boundary], :name, nil)

  @spec output_dir(module()) :: String.t()
  def output_dir(module), do: Extension.get_opt(module, [:boundary], :output_dir, "priv/boundary")

  @spec environments(module()) :: [AshCompliance.Boundary.Environment.t()]
  def environments(module), do: Extension.get_entities(module, [:environments])

  @spec resources(module()) :: [AshCompliance.Boundary.Resource.t()]
  def resources(module), do: Extension.get_entities(module, [:resources])

  @spec controls(module()) :: [AshCompliance.Boundary.Control.t()]
  def controls(module), do: Extension.get_entities(module, [:controls])

  @doc "True when `module` is a boundary declaration."
  @spec declaration?(module()) :: boolean()
  def declaration?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) and
      AshCompliance.Boundary in Spark.extensions(module)
  rescue
    _ -> false
  end

  defp sort_by(list, fun), do: Enum.sort_by(list, &to_string(fun.(&1)))
end
