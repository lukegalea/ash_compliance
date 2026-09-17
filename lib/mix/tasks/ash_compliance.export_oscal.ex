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

    # Ops tooling: raw `Ash` calls here would bypass the domain contract, and
    # a mix task has no actor to attribute. The trusted-machinery bypass is
    # the package's documented default for host-facing entry points; the
    # Oscal functions accept `actor:`/`authorize?:` for wired contexts.
    result =
      case type do
        "catalog" ->
          case AshCompliance.Domain.get_catalog_by_id(normalize_uuid(id), authorize?: false) do
            {:ok, %AshCompliance.Resources.Catalog{} = catalog} ->
              AshCompliance.Oscal.export_catalog(catalog)

            _ ->
              {:error, :does_not_exist}
          end

        "profile" ->
          case AshCompliance.Domain.get_profile_by_id(normalize_uuid(id), authorize?: false) do
            {:ok, %AshCompliance.Resources.Profile{} = profile} ->
              AshCompliance.Oscal.export_profile(profile)

            _ ->
              {:error, :does_not_exist}
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
