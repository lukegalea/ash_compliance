# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.Gate do
  @moduledoc """
  Puts the separation-of-duties decision in front of an Ash action.

  `attach/2` adds two hooks to a changeset:

    * before the transaction opens: the resolver names the organization and the
      approval attributes; the decision is asked; a refusal is recorded as an
      `AshCompliance.Resources.ApprovalAttempt` and adds an error, so the action
      does not run. Recording happens outside any transaction, so nothing can
      roll the refusal back
    * after the action, in its transaction: a permit is recorded the same way,
      and if that write fails the action fails with it

  The resolver receives the changeset inside the first hook and returns
  `{:ok, organization_id, attrs}` (see `AshCompliance.Processes.Approval`) or
  `{:error, message}` when the attributes cannot be established, which fails
  the action without recording an attempt.
  """

  alias AshCompliance.Processes.Approval

  @context_key :ash_compliance_separation

  @type resolver :: (Ash.Changeset.t() ->
                       {:ok, String.t(), Approval.attrs()} | {:error, String.t()})

  @spec attach(Ash.Changeset.t(), resolver()) :: Ash.Changeset.t()
  def attach(changeset, resolver) when is_function(resolver, 1) do
    changeset
    |> Ash.Changeset.before_transaction(&ask(&1, resolver))
    |> Ash.Changeset.after_action(&record_permit/2)
  end

  defp ask(changeset, resolver) do
    case resolver.(changeset) do
      {:error, message} ->
        Ash.Changeset.add_error(changeset, message: message)

      {:ok, organization_id, attrs} ->
        verdict = Approval.verdict(attrs)

        changeset =
          Ash.Changeset.set_context(changeset, %{
            @context_key => %{organization_id: organization_id, attrs: attrs, verdict: verdict}
          })

        case verdict.outcome do
          :permit ->
            changeset

          :refuse ->
            _ = Approval.record(organization_id, attrs, verdict)

            Ash.Changeset.add_error(changeset,
              message: "separation of duties: refused (#{verdict.reason})"
            )
        end
    end
  end

  defp record_permit(changeset, record) do
    case changeset.context[@context_key] do
      %{verdict: %{outcome: :permit} = verdict, organization_id: org, attrs: attrs} ->
        case Approval.record(org, attrs, verdict) do
          {:ok, _attempt} -> {:ok, record}
          {:error, error} -> {:error, error}
        end

      _ ->
        {:error, "separation of duties was not asked, so the action is refused"}
    end
  end
end
