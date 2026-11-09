# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.GeneratedFiles do
  @moduledoc """
  The neutral hook between a declaration and codegen.

  A Spark extension that generates files implements `generated_files/1`.
  Codegen asks every extension a declaration uses and merges the answers, so
  it never needs to know which extensions exist. Two extensions may not
  generate the same file name.
  """

  @doc "A map of file name to contents, rendered from the declaration `module`."
  @callback generated_files(module()) :: %{String.t() => String.t()}

  @doc "The names of every file this extension can generate, for any declaration."
  @callback file_names() :: [String.t()]

  @optional_callbacks file_names: 0

  @doc """
  Files on disk in `dir` that an extension of this library owns but that the
  declaration `module` no longer generates, because the extension was removed.
  """
  @spec stale(module(), String.t()) :: [String.t()]
  def stale(module, dir) do
    current = module |> files() |> Map.keys()

    owned =
      __MODULE__
      |> Application.get_application()
      |> Application.spec(:modules)
      |> List.wrap()
      |> Enum.filter(&implements?/1)
      |> Enum.flat_map(& &1.file_names())

    (owned -- current)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&File.exists?(Path.join(dir, &1)))
  end

  defp implements?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :file_names, 0) and
      __MODULE__ in List.wrap(mod.module_info(:attributes)[:behaviour])
  end

  @doc "Every file the declaration's extensions generate."
  @spec files(module()) :: %{String.t() => String.t()}
  def files(module) do
    module
    |> Spark.extensions()
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :generated_files, 1)))
    |> Enum.reduce(%{}, fn extension, acc ->
      Map.merge(acc, extension.generated_files(module), fn name, _a, _b ->
        raise ArgumentError, "two extensions generate #{name} for #{inspect(module)}"
      end)
    end)
  end
end
