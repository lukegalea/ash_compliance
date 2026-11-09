# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Codegen do
  @moduledoc """
  Writes, or checks, the files generated from declarations.

  The files come from `AshCompliance.Boundary.GeneratedFiles`: every
  extension a declaration uses contributes its own.

  The generated files are the snapshot: a check renders each declaration in
  memory and compares it with what is on disk. Any file that is missing or
  differs is pending. Nothing is read back from the disk but the files being
  compared.
  """

  alias AshCompliance.Boundary.{GeneratedFiles, Info}

  @type opts :: [check: boolean(), dry_run: boolean(), output_dir: String.t() | nil]

  @doc "Writes the pending files of one declaration, or with `check: true` or `dry_run: true` writes nothing. Returns the pending paths."
  @spec run(module(), opts()) :: [String.t()]
  def run(module, opts \\ []) do
    dir = Keyword.get(opts, :output_dir) || Info.output_dir(module)
    files = GeneratedFiles.files(module)

    pending =
      files
      |> Enum.sort()
      |> Enum.reject(fn {name, content} -> File.read(Path.join(dir, name)) == {:ok, content} end)

    stale = GeneratedFiles.stale(module, dir)
    pending_paths = Enum.map(pending, fn {name, _} -> Path.join(dir, name) end)
    stale_paths = Enum.map(stale, &Path.join(dir, &1))

    cond do
      Keyword.get(opts, :check, false) ->
        pending_paths ++ stale_paths

      Keyword.get(opts, :dry_run, false) ->
        Enum.each(pending, fn {name, content} ->
          Mix.shell().info("# #{Path.join(dir, name)}\n#{content}")
        end)

        Enum.each(stale_paths, &Mix.shell().info("# remove #{&1}"))
        pending_paths ++ stale_paths

      true ->
        File.mkdir_p!(dir)
        Enum.each(stale_paths, &File.rm!/1)

        written =
          Enum.map(pending, fn {name, content} ->
            path = Path.join(dir, name)
            File.write!(path, content)
            path
          end)

        written ++ stale_paths
    end
  end

  @doc "Every declaration compiled into the current project's applications."
  @spec discover() :: [module()]
  def discover do
    apps =
      if apps_paths = Mix.Project.apps_paths(),
        do: Map.keys(apps_paths),
        else: [Mix.Project.config()[:app]]

    apps
    |> Enum.flat_map(&(Application.spec(&1, :modules) || []))
    |> Enum.filter(&Info.declaration?/1)
    |> Enum.sort()
  end
end
