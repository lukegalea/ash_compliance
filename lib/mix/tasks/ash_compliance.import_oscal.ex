# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshCompliance.ImportOscal do
  @moduledoc """
  Imports an OSCAL catalog or profile JSON document.

      mix ash_compliance.import_oscal catalog.json --type catalog
      mix ash_compliance.import_oscal profile.json --type profile --org <uuid> --catalog <uuid>

  Options:

    * `--type` — `catalog` or `profile` (default: `catalog`)
    * `--org` — the organization uuid (required for profiles; optional for
      catalogs — omit for a shared catalog)
    * `--catalog` — the catalog uuid a profile tailors (profiles only)

  The host's repo is read from application env (`config :ash_compliance,
  repo:`), so this task runs inside the host application.
  """

  use Mix.Task

  @requirements ["app.start"]

  @shortdoc "Imports an OSCAL catalog or profile JSON document"

  @impl Mix.Task
  def run(args) do
    {opts, positional} =
      OptionParser.parse!(args, strict: [type: :string, org: :string, catalog: :string])

    file =
      List.first(positional) ||
        Mix.raise("usage: mix ash_compliance.import_oscal <file> --type catalog|profile")

    document = File.read!(file)
    type = Keyword.get(opts, :type, "catalog")
    organization_id = opts[:org] && normalize_uuid(opts[:org])

    # Ops tooling: a mix task has no actor to attribute, so the import runs
    # under the package's trusted-machinery default. `AshCompliance.Oscal`
    # accepts `actor:`/`authorize?:` for hosts that call it from wired code.
    result =
      case type do
        "catalog" ->
          AshCompliance.Oscal.import_catalog(document, organization_id: organization_id)

        "profile" ->
          AshCompliance.Oscal.import_profile(document,
            organization_id: organization_id || Mix.raise("--org is required for profiles"),
            catalog_id: opts[:catalog] && normalize_uuid(opts[:catalog])
          )

        other ->
          Mix.raise("unknown --type #{inspect(other)}; use catalog or profile")
      end

    case result do
      {:ok, record} ->
        Mix.shell().info("imported #{type} #{record.name} (#{record.id})")

      {:error, errors} ->
        Mix.raise(List.wrap(errors) |> Enum.join("; "))
    end
  end

  defp normalize_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Mix.raise("#{inspect(value)} is not a uuid")
    end
  end
end
