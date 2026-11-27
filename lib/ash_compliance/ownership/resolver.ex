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
    * `scheme:value` for a scheme the host configures
      (`AshCompliance.Ownership.ReferenceScheme`), which answers for it

  Anything else, or a reference that does not exist, is unresolvable. Module
  and task lookups search the code path for the beam file and never create
  atoms from file content.
  """

  @type result :: :ok | {:error, String.t()}

  @builtin ~w(module mix file)

  @doc """
  The reference schemes the host configures, by name:
  `config :ash_compliance, reference_schemes: %{"journey" => MyApp.JourneyReference}`.
  """
  @spec schemes() :: %{String.t() => module()}
  def schemes,
    do: Map.drop(Application.get_env(:ash_compliance, :reference_schemes, %{}), @builtin)

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

  def resolve(ref, root) when is_binary(ref) and ref != "" do
    case configured(ref) do
      {scheme, value} -> scheme.resolve(value, root)
      nil -> {:error, "#{inspect(ref)} is not #{known()} reference"}
    end
  end

  def resolve(_ref, _root), do: {:error, "reference is missing or not a string"}

  @doc """
  Whether the producer `ref` declares that it records evidence for `criterion`.

  A producer module (or Mix task module) proves it by exporting
  `evidence_controls/0`, the list of criterion ids it records artifacts for.
  Existing on the code path proves nothing, and a `file:` reference cannot
  declare anything, so it is never proven. A configured scheme answers for its
  own references (`c:AshCompliance.Ownership.ReferenceScheme.proves_producer/2`).
  """
  @spec proves_producer(term(), String.t()) :: result()
  def proves_producer("module:" <> name, criterion) when name != "",
    do: declares(["Elixir." <> String.replace_prefix(name, "Elixir.", "")], name, criterion)

  def proves_producer("mix:" <> task, criterion) when task != "" do
    parts = task |> String.split(".") |> Enum.map(&Macro.camelize/1)
    declares(["Elixir", "Mix", "Tasks" | parts], "mix task " <> task, criterion)
  end

  def proves_producer(ref, criterion) when is_binary(ref) do
    case configured(ref) do
      {scheme, value} -> scheme.proves_producer(value, criterion)
      nil -> {:error, "#{inspect(ref)} cannot declare that it records evidence"}
    end
  end

  def proves_producer(_ref, _criterion), do: {:error, "reference is missing or not a string"}

  defp declares(parts, label, criterion) do
    module = parts |> Enum.reject(&(&1 == "Elixir")) |> Module.safe_concat()

    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :evidence_controls, 0),
         ids when is_list(ids) <- module.evidence_controls(),
         true <- criterion in ids do
      :ok
    else
      _ -> {:error, "#{label} does not declare that it records evidence for #{criterion}"}
    end
  rescue
    ArgumentError -> {:error, "#{label} is not on the code path"}
  end

  defp configured(ref) do
    with [name, value] when value != "" <- String.split(ref, ":", parts: 2),
         {:ok, scheme} <- Map.fetch(schemes(), name) do
      {scheme, value}
    else
      _ -> nil
    end
  end

  defp known do
    names = Enum.map(@builtin ++ Enum.sort(Map.keys(schemes())), &(&1 <> ":"))
    {init, [last]} = Enum.split(names, -1)
    "a " <> Enum.join(init, ", ") <> " or " <> last
  end

  defp beam_present?(beam, label) do
    case :code.where_is_file(String.to_charlist(beam)) do
      :non_existing -> {:error, "#{label} is not on the code path"}
      _ -> :ok
    end
  end
end
