# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Oban) do
  defmodule AshCompliance.Workers.EvidenceFreshness do
    @moduledoc """
    The scheduled freshness sweep.

    Runs `AshCompliance.Ownership.Sweep` for one organization: stale evidence
    or an overdue process becomes `:unknown` and raises a `Finding`.
    The worker succeeds whenever the sweep ran, however many criteria came
    out unknown. It reports; it never fails a job, a deploy or a request
    because of what it found. It fails (and Oban retries) only when the sweep
    itself could not run.

    Scheduling (in the host):

        config :my_app, Oban,
          queues: [compliance: 1],
          plugins: [
            {Oban.Plugins.Cron,
             crontab: [
               {"15 * * * *", AshCompliance.Workers.EvidenceFreshness,
                args: %{
                  "organization_id" => "<uuid>",
                  "controls_file" => "docs/controls.json",
                  "categories" => ["security"]
                }}
             ]}
          ]

    Args: `organization_id` (uuid), `controls_file` (path), `categories`
    (list of category names; default `["security"]`).
    """

    use Oban.Worker,
      queue: :compliance,
      max_attempts: 3,
      unique: [period: 300, keys: [:organization_id, :controls_file, :categories]]

    alias AshCompliance.Ownership.{Criteria, Sweep}

    @impl Oban.Worker
    def perform(%Oban.Job{args: args}) do
      with {:ok, organization_id} <- fetch_uuid(args),
           {:ok, controls_file} <- fetch_file(args),
           {:ok, categories} <- categories(args),
           {:ok, _results} <-
             Sweep.run(organization_id, controls_file: controls_file, categories: categories) do
        :ok
      else
        {:cancel, _} = cancel -> cancel
        {:error, error} -> {:error, error}
      end
    end

    defp fetch_uuid(%{"organization_id" => id}) do
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:ok, uuid}
        :error -> {:cancel, "organization_id is not a uuid"}
      end
    end

    defp fetch_uuid(_), do: {:cancel, "organization_id is required"}

    defp fetch_file(%{"controls_file" => file}) when is_binary(file) and file != "",
      do: {:ok, file}

    defp fetch_file(_), do: {:cancel, "controls_file is required"}

    defp categories(%{"categories" => names}) when is_list(names) and names != [] do
      known = Map.new(Criteria.categories(), &{Atom.to_string(&1), &1})

      parsed = Enum.map(names, &Map.get(known, &1))

      if Enum.any?(parsed, &is_nil/1),
        do: {:cancel, "unknown category in #{inspect(names)}"},
        else: {:ok, Enum.uniq(parsed)}
    end

    defp categories(%{"categories" => _}), do: {:cancel, "categories must be a non-empty list"}
    defp categories(_), do: {:ok, [:security]}
  end
end
