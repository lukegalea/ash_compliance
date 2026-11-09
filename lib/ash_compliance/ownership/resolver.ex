# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Resolver do
  @moduledoc """
  Resolves the references a control file makes to code and documents.

  A reference is `scheme:value`:

    * `module:Elixir.Module.Name` or `module:Module.Name` - a compiled module
      found on the code path
    * `mix:task.name` - a Mix task, for example `mix:ash_compliance.controls.check`
    * `file:relative/path` - a file under the host root

  Anything else, or a reference that does not exist, is unresolvable. Module
  and task lookups search the code path for the beam file and never create
  atoms from file content.
  """

  @type result :: :ok | {:error, String.t()}

  @doc "Resolves `ref` relative to `root`."
  @spec resolve(term(), Path.t()) :: result()
  def resolve(ref, root \\ File.cwd!())

  def resolve("module:" <> name, _root) when name != "" do
    beam = "Elixir." <> String.replace_prefix(name, "Elixir.", "") <> ".beam"
    beam_present?(beam, "module #{name}")
  end

  def resolve("mix:" <> task, _root) when task != "" do
    module =
      task
      |> String.split(".")
      |> Enum.map_join(".", &Macro.camelize/1)

    beam_present?("Elixir.Mix.Tasks." <> module <> ".beam", "mix task #{task}")
  end

  def resolve("file:" <> path, root) when path != "" do
    if File.exists?(Path.expand(path, root)),
      do: :ok,
      else: {:error, "file #{path} does not exist"}
  end

  def resolve(ref, _root) when is_binary(ref) and ref != "",
    do: {:error, "#{inspect(ref)} is not a module:, mix: or file: reference"}

  def resolve(_ref, _root), do: {:error, "reference is missing or not a string"}

  defp beam_present?(beam, label) do
    case :code.where_is_file(String.to_charlist(beam)) do
      :non_existing -> {:error, "#{label} is not on the code path"}
      _ -> :ok
    end
  end
end
