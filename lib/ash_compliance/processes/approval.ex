# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.Approval do
  @moduledoc """
  The gate an approval passes through, and the record it leaves.

  `decide/3` asks `AshCompliance.Processes.SeparationOfDuties` whether the
  approver may approve the requester's request, writes an
  `AshCompliance.Resources.ApprovalAttempt` for the answer, and returns
  `:ok`-style only for a recorded permit:

    * `{:ok, attempt}` - permitted, and the permit is on record
    * `{:error, {:refused, reason, attempt}}` - refused, and the refusal is on
      record (`attempt` is `nil` only when the refusal itself could not be
      written; the caller must still treat the approval as refused)
    * `{:error, {:unrecorded, error}}` - the decision permitted but the record
      could not be written. An approval that cannot be recorded is not an
      approval.

  Attempts are written outside any caller transaction when you call `decide/3`
  directly. Code that runs inside an Ash action should use `verdict/1` and
  `record/4`, so a refusal can be written after the action's transaction has
  rolled back.
  """

  alias AshCompliance.Domain
  alias AshCompliance.Processes.SeparationOfDuties

  @type attrs :: %{
          required(:process_key) => String.t(),
          required(:subject_id) => String.t(),
          optional(:requester_id) => term(),
          optional(:approver_id) => term(),
          optional(:delegators) => term()
        }

  @doc """
  Decides and records. `attrs` carries `:process_key`, `:subject_id`,
  `:requester_id`, `:approver_id` and `:delegators` (a list, empty for none;
  `nil` for "not recorded", which is refused).
  """
  @spec decide(String.t(), attrs(), keyword()) ::
          {:ok, struct()} | {:error, {:refused, String.t(), struct() | nil}} | {:error, term()}
  def decide(organization_id, attrs, opts \\ []) do
    verdict = verdict(attrs)

    case {verdict.outcome, record(organization_id, attrs, verdict, opts)} do
      {:permit, {:ok, attempt}} -> {:ok, attempt}
      {:permit, {:error, error}} -> {:error, {:unrecorded, error}}
      {:refuse, {:ok, attempt}} -> {:error, {:refused, verdict.reason, attempt}}
      {:refuse, {:error, _}} -> {:error, {:refused, verdict.reason, nil}}
    end
  end

  @doc "The separation decision's verdict for `attrs`, without recording anything."
  @spec verdict(attrs()) :: SeparationOfDuties.verdict()
  def verdict(attrs) do
    SeparationOfDuties.check(
      Map.get(attrs, :requester_id),
      Map.get(attrs, :approver_id),
      Map.get(attrs, :delegators)
    )
  end

  @doc "Writes the attempt row for a verdict."
  @spec record(String.t(), attrs(), SeparationOfDuties.verdict(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def record(organization_id, attrs, verdict, opts \\ []) do
    delegators = Map.get(attrs, :delegators)

    Domain.record_approval_attempt(
      %{
        organization_id: organization_id,
        process_key: Map.get(attrs, :process_key),
        subject_id: Map.get(attrs, :subject_id),
        requester_id: text(Map.get(attrs, :requester_id)),
        approver_id: text(Map.get(attrs, :approver_id)),
        delegation_chain: if(chain?(delegators), do: delegators, else: []),
        delegation_recorded?: chain?(delegators),
        outcome: if(verdict.outcome == :permit, do: :permitted, else: :refused),
        reason: verdict.reason,
        decision_hash: verdict.decision_hash
      },
      actor: opts[:actor],
      authorize?: Keyword.get(opts, :authorize?, false)
    )
  end

  @doc "Every attempt recorded for a subject, permitted or refused."
  @spec attempts_for(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def attempts_for(organization_id, process_key, subject_id, opts \\ []) do
    Domain.approval_attempts_for_subject(
      organization_id,
      process_key,
      subject_id,
      actor: opts[:actor],
      authorize?: Keyword.get(opts, :authorize?, false)
    )
  end

  @doc "Like `attempts_for/4`, raising on failure."
  @spec attempts_for!(String.t(), String.t(), String.t(), keyword()) :: [struct()]
  def attempts_for!(organization_id, process_key, subject_id, opts \\ []) do
    {:ok, attempts} = attempts_for(organization_id, process_key, subject_id, opts)
    attempts
  end

  defp chain?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)
  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil
end
