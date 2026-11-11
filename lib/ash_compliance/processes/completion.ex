# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.Completion do
  @moduledoc """
  Writes the evidence a finished process leaves behind.

  `complete/4` records one `AshCompliance.Resources.EvidenceArtifact` per
  criterion the template supports, through the evidence writer
  (`AshCompliance.Ownership.Evidence`). The artifact's collector is the
  reference the host's control file carries for the process, because the
  freshness evaluator counts only artifacts from a source the row declares.

  ## What completes

  Only an instance that ended `completed`. A rejected, refused, expired,
  not-completed or recorded-only instance leaves no artifact, so the control
  reads as stale instead of as evidenced by a process that did not finish.

  Nothing is recorded unless all of these hold, and each failure is its own
  error:

    * the template exists
    * the outcome is `"completed"`
    * the instance id and the person who completed it are present
    * the collector is present
    * for a template with an approval, at least one `permitted`
      `AshCompliance.Resources.ApprovalAttempt` is on record for this process
      and instance. A completion with no recorded approval is refused, however
      the instance got there
    * the summary can be encoded as JSON

  The artifact is evidence that the process ran and who finished it. It is not a
  claim that the review was a good one.
  """

  alias AshCompliance.Ownership.Evidence
  alias AshCompliance.Processes.{Approval, Canonical, Templates}

  @type attrs :: %{
          required(:instance_id) => String.t(),
          required(:completed_by) => String.t(),
          required(:outcome) => String.t(),
          optional(:summary) => map()
        }

  @doc """
  Records completion evidence for `template_key`.

  Options: `:collector` (required), `:now`, `:collected_at`, `:actor`,
  `:authorize?`, `:retention_class`, `:location` and `:store_content`; the last five go
  to the evidence writer.
  """
  @spec complete(String.t(), String.t(), attrs(), keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def complete(organization_id, template_key, attrs, opts) do
    with {:ok, template} <- template(template_key),
         :ok <- outcome(attrs),
         {:ok, instance_id} <- present(attrs, :instance_id),
         {:ok, completed_by} <- present(attrs, :completed_by),
         {:ok, approvals} <- approvals(organization_id, template, instance_id, opts),
         {:ok, summary} <- summary(attrs) do
      record_all(organization_id, template, instance_id, completed_by, approvals, summary, opts)
    end
  end

  defp template(key) do
    case Templates.get(key) do
      nil -> {:error, {:unknown_template, key}}
      template -> {:ok, template}
    end
  end

  defp outcome(%{outcome: "completed"}), do: :ok
  defp outcome(%{outcome: other}), do: {:error, {:not_completed, other}}
  defp outcome(_), do: {:error, {:not_completed, nil}}

  defp present(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:missing, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing, key}}
    end
  end

  defp approvals(_org, %{approval?: false}, _instance, _opts), do: {:ok, []}

  defp approvals(org, template, instance_id, opts) do
    case Approval.attempts_for(org, template.process_key, instance_id, opts) do
      {:ok, attempts} ->
        case Enum.filter(attempts, &(&1.outcome == :permitted)) do
          [] -> {:error, :no_recorded_approval}
          permitted -> {:ok, permitted |> Enum.map(& &1.id) |> Enum.sort()}
        end

      {:error, error} ->
        {:error, {:approvals_unreadable, error}}
    end
  end

  defp summary(attrs) do
    summary = Map.get(attrs, :summary, %{})

    if is_map(summary) do
      {:ok, Canonical.encode!(summary) |> Jason.decode!()}
    else
      {:error, :summary_not_a_map}
    end
  rescue
    _ -> {:error, :summary_not_encodable}
  end

  defp record_all(org, template, instance_id, completed_by, approvals, summary, opts) do
    collector = Keyword.get(opts, :collector)

    Enum.reduce_while(template.criteria, {:ok, []}, fn criterion, {:ok, acc} ->
      content =
        Canonical.encode!(%{
          "process" => template.process_key,
          "template_hash" => Templates.content_hash(template),
          "criterion" => criterion,
          "instance_id" => instance_id,
          "completed_by" => completed_by,
          "outcome" => "completed",
          "approvals" => approvals,
          "summary" => summary
        })

      writer_opts =
        opts
        |> Keyword.take([
          :now,
          :collected_at,
          :actor,
          :authorize?,
          :retention_class,
          :location,
          :store_content
        ])
        |> Keyword.merge(
          producer: collector,
          media_type: "application/json",
          method: :examine,
          subject_type: "process_instance",
          subject_id: instance_id
        )

      case Evidence.record(org, criterion, content, writer_opts) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end
end
