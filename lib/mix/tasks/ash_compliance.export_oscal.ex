# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshCompliance.ExportOscal do
  @moduledoc """
  Exports a catalog or profile as an OSCAL-shaped JSON document.

      mix ash_compliance.export_oscal --type catalog --id <catalog-uuid> --to catalog.json
      mix ash_compliance.export_oscal --type profile --id <profile-uuid>

  Prints the document when `--to` is omitted.
  """

  use Mix.Task

  @requirements ["app.start"]

  @shortdoc "Exports a catalog or profile as an OSCAL JSON document"

  @impl Mix.Task
  def run(args) do
    {opts, _positional} =
      OptionParser.parse!(args, strict: [type: :string, id: :string, to: :string])

    type = Keyword.get(opts, :type, "catalog")
    id = opts[:id] || Mix.raise("--id is required")

    result =
      case type do
        "catalog" ->
          with {:ok, catalog} <-
                 Ash.get(AshCompliance.Resources.Catalog, normalize_uuid(id), authorize?: false) do
            AshCompliance.Oscal.export_catalog(catalog)
          end

        "profile" ->
          with {:ok, profile} <-
                 Ash.get(AshCompliance.Resources.Profile, normalize_uuid(id), authorize?: false) do
            AshCompliance.Oscal.export_profile(profile)
          end

        other ->
          Mix.raise("unknown --type #{inspect(other)}; use catalog or profile")
      end

    case result do
      {:ok, document} ->
        json = Jason.encode!(document, pretty: true)

        case opts[:to] do
          nil -> Mix.shell().info(json)
          path -> File.write!(path, json <> "\n")
        end

      {:error, _} ->
        Mix.raise("#{type} #{inspect(id)} does not exist")
    end
  end

  defp normalize_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Mix.raise("#{inspect(value)} is not a uuid")
    end
  end
end
