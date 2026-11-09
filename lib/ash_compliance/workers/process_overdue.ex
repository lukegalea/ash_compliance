# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Oban) do
  defmodule AshCompliance.Workers.ProcessOverdue do
    @moduledoc """
    The scheduled overdue-task sweep.

    Runs `AshCompliance.Processes.Overdue` for one organization. The worker
    succeeds whenever the sweep ran, however many tasks were overdue; it fails,
    and Oban retries, when the task source could not be read.

    Scheduling (in the host):

        {"30 * * * *", AshCompliance.Workers.ProcessOverdue,
         args: %{
           "organization_id" => "<uuid>",
           "task_source" => "MyApp.Compliance.TaskSource"
         }}

    `task_source` must name a module that is already loaded and implements
    `AshCompliance.Processes.TaskSource`; no atom is created from the argument.
    """

    use Oban.Worker,
      queue: :compliance,
      max_attempts: 3,
      unique: [period: 300, keys: [:organization_id, :task_source]]

    alias AshCompliance.Processes.Overdue

    @impl Oban.Worker
    def perform(%Oban.Job{args: args}) do
      with {:ok, organization_id} <- uuid(args),
           {:ok, source} <- source(args),
           {:ok, _overdue} <- Overdue.sweep(organization_id, source) do
        :ok
      else
        {:cancel, _} = cancel -> cancel
        {:error, error} -> {:error, error}
      end
    end

    defp uuid(%{"organization_id" => id}) do
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:ok, uuid}
        :error -> {:cancel, "organization_id is not a uuid"}
      end
    end

    defp uuid(_), do: {:cancel, "organization_id is missing"}

    defp source(%{"task_source" => name}) when is_binary(name) do
      module = String.to_existing_atom("Elixir." <> String.replace_prefix(name, "Elixir.", ""))

      if Code.ensure_loaded?(module) and function_exported?(module, :open_tasks, 2),
        do: {:ok, module},
        else: {:cancel, "task_source is not a loaded TaskSource module"}
    rescue
      ArgumentError -> {:cancel, "task_source is not a loaded module"}
    end

    defp source(_), do: {:cancel, "task_source is missing"}
  end
end
