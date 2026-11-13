# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.ApprovalAttempt.Changes.Decide do
  @moduledoc """
  Sets `outcome`, `reason` and `decision_hash` from the separation-of-duties
  decision, asked with the requester, approver and delegation chain being
  recorded. The caller cannot supply them, so a row cannot say `:permitted`
  unless the decision permitted the people it names.

  A chain marked as not recorded (`delegation_recorded?: false`) is passed as
  `nil`, which the decision refuses.
  """

  use Ash.Resource.Change

  alias AshCompliance.Processes.SeparationOfDuties

  @impl true
  def change(changeset, _opts, _context) do
    delegators =
      if Ash.Changeset.get_attribute(changeset, :delegation_recorded?),
        do: Ash.Changeset.get_attribute(changeset, :delegation_chain),
        else: nil

    verdict =
      SeparationOfDuties.check(
        Ash.Changeset.get_attribute(changeset, :requester_id),
        Ash.Changeset.get_attribute(changeset, :approver_id),
        delegators
      )

    Ash.Changeset.force_change_attributes(changeset, %{
      outcome: if(SeparationOfDuties.permit?(verdict), do: :permitted, else: :refused),
      reason: verdict.reason,
      decision_hash: verdict.decision_hash
    })
  end
end
