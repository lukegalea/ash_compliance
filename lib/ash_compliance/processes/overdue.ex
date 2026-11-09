# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.Overdue do
  @moduledoc """
  Turns an overdue process task into a `Finding`.

  `sweep/3` reads the open tasks from a `AshCompliance.Processes.TaskSource`
  and, for each task past its due time, files a finding against every criterion
  the task's template supports, under the grain
  `{organization, criterion, "process_overdue", task id}`. The finding's status
  is `:unknown`; a late review is not a failed control, it is a control whose
  operation is not established.

  ## What is overdue

    * a task past its due time
    * a task whose due time is missing or malformed
    * a task for a process key that no template defines (it is filed against
      the pseudo control `"process:unclassified"` so it cannot disappear)

  ## What a source failure means

  If the source returns an error, raises, or returns something that is not a list
  of tasks, the sweep files a finding against the pseudo control
  `"process:task-source"` and returns `{:error, {:source_failed, reason}}`. It
  never resolves any finding on a failed read, because a read that failed says
  nothing about whether the tasks are still open.

  ## Resolution

  A finding for a task that is no longer open is resolved (`resolved_at` set) on
  the next successful sweep. Its status stays `:unknown`: closing the task shows
  the process ran, not that the control is compliant.
  """

  alias AshCompliance.Domain
  alias AshCompliance.Processes.Templates

  @subject_type "process_overdue"
  @unclassified "process:unclassified"
  @source_control "process:task-source"
  @source_subject "task-source"

  @doc "The finding subject type overdue findings are filed under."
  def subject_type, do: @subject_type

  @doc """
  Sweeps `organization_id`.

  Options: `:now`, `:actor`, `:authorize?` (default `false`), `:source_opts`
  (handed to the source).

  Returns `{:ok, overdue}` with one entry per overdue task.
  """
  @spec sweep(String.t(), module(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def sweep(organization_id, source, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ash_opts = [actor: opts[:actor], authorize?: Keyword.get(opts, :authorize?, false)]

    case read(source, organization_id, Keyword.get(opts, :source_opts, [])) do
      {:ok, tasks} ->
        classified = Enum.map(tasks, &classify(&1, now))
        overdue = for {:overdue, entry} <- classified, do: entry
        present = for {_, %{task_id: id}} <- classified, do: id
        present = present ++ for {:open, id} <- classified, do: id

        with :ok <- file_all(organization_id, overdue, now, ash_opts),
             :ok <- resolve_closed(organization_id, present, now, ash_opts),
             :ok <- resolve(organization_id, @source_control, @source_subject, now, ash_opts) do
          {:ok, overdue}
        end

      {:error, reason} ->
        _ =
          file(
            organization_id,
            @source_control,
            @source_subject,
            now,
            ash_opts,
            "task source failed: " <> inspect(reason, limit: 5)
          )

        {:error, {:source_failed, reason}}
    end
  end

  defp read(source, organization_id, source_opts) do
    case source.open_tasks(organization_id, source_opts) do
      {:ok, tasks} when is_list(tasks) -> {:ok, tasks}
      {:ok, other} -> {:error, {:not_a_list, other}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp classify(task, now) do
    id = task_id(task)
    key = field(task, :process_key)
    due = field(task, :due_at)
    template = Templates.get(key)

    cond do
      id == nil ->
        {:overdue,
         entry(
           "malformed-#{:erlang.phash2(task)}",
           key,
           nil,
           template,
           "malformed_task",
           "the task has no id"
         )}

      not match?(%DateTime{}, due) ->
        {:overdue,
         entry(id, key, nil, template, "malformed_task", "the task has no valid due time")}

      DateTime.compare(due, now) == :lt ->
        {:overdue, entry(id, key, due, template, "overdue", "due #{DateTime.to_iso8601(due)}")}

      true ->
        {:open, id}
    end
  end

  defp entry(id, key, due, template, reason, detail) do
    %{
      task_id: id,
      process_key: key,
      due_at: due,
      controls: if(template, do: template.criteria, else: [@unclassified]),
      reason: reason,
      detail: detail
    }
  end

  defp file_all(organization_id, overdue, now, ash_opts) do
    Enum.reduce_while(overdue, :ok, fn entry, :ok ->
      explanation =
        "#{entry.reason}: #{entry.process_key || "no process"} task #{entry.task_id} #{entry.detail}"

      result =
        Enum.reduce_while(entry.controls, :ok, fn control, :ok ->
          case file(organization_id, control, entry.task_id, now, ash_opts, explanation) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp file(organization_id, control, subject_id, now, ash_opts, explanation) do
    grain = grain(organization_id, control, subject_id)

    existing = existing(organization_id, ash_opts)[{control, subject_id}]

    first_seen =
      if existing && existing.first_seen_at, do: [], else: [{:set, :first_seen_at, now}]

    ops =
      first_seen ++
        [
          {:set, :status, :unknown},
          {:set, :gap, "process_overdue"},
          {:set, :last_seen_at, now},
          {:set, :resolved_at, nil},
          {:set, :explanation, explanation}
        ]

    with {:ok, row} <- Domain.upsert_finding_grain(grain, ash_opts),
         {:ok, _} <- Domain.apply_finding_ops(row, ops, ash_opts) do
      :ok
    end
  end

  defp resolve_closed(organization_id, still_open, now, ash_opts) do
    organization_id
    |> existing(ash_opts)
    |> Enum.reject(fn {{control, subject_id}, finding} ->
      finding.resolved_at != nil or control == @source_control or subject_id in still_open
    end)
    |> Enum.reduce_while(:ok, fn {{control, subject_id}, _}, :ok ->
      case resolve(organization_id, control, subject_id, now, ash_opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve(organization_id, control, subject_id, now, ash_opts) do
    case existing(organization_id, ash_opts)[{control, subject_id}] do
      %{resolved_at: nil} = finding ->
        ops = [
          {:set, :resolved_at, now},
          {:set, :last_seen_at, now},
          {:set, :explanation, "no longer open or overdue"}
        ]

        with {:ok, _} <- Domain.apply_finding_ops(finding, ops, ash_opts), do: :ok

      _ ->
        :ok
    end
  end

  defp existing(organization_id, ash_opts) do
    case Domain.findings_for_organization(organization_id, ash_opts) do
      {:ok, findings} ->
        for %{subject_type: @subject_type} = finding <- findings,
            into: %{},
            do: {{finding.control_id, finding.subject_id}, finding}

      {:error, _} ->
        %{}
    end
  end

  defp grain(organization_id, control, subject_id) do
    %{
      organization_id: organization_id,
      control_id: control,
      subject_type: @subject_type,
      subject_id: subject_id
    }
  end

  defp task_id(task) do
    case field(task, :id) do
      id when is_binary(id) -> if String.trim(id) == "", do: nil, else: id
      _ -> nil
    end
  end

  defp field(%{} = task, key), do: Map.get(task, key)
  defp field(_, _), do: nil
end
