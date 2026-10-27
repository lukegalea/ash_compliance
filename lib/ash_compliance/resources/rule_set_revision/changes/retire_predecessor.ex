# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.RuleSetRevision.Changes.RetirePredecessor do
  @moduledoc """
  `:activate` succeeds the in-force revision of the same name: the active
  predecessor retires in the same transaction, at the same write instant.

  The documented lifecycle is activate-2-then-retire-1 — a successor's
  activation closes the predecessor's period, so the editor never performs
  the manual retire between revisions and no instant exists where the name
  is in force twice or absent entirely. The split rides the same period
  machinery as every other lifecycle write: the predecessor's active
  period `[t0, ∞)` becomes `[t0, t)` and the successor opens `[t, ∞)` —
  adjacent, so the `one_active_per_name` exclusion still guards any
  genuinely-overlapping pair (e.g. two activations of different names are
  untouched, and an incoherent historical instant still refuses).

  Runs in `around_transaction`, so the predecessor's retire and the
  subject's activation commit or roll back together.
  """

  use Ash.Resource.Change

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.around_transaction(changeset, fn changeset, callback ->
      instant = write_instant(changeset)

      predecessors =
        AshCompliance.Resources.RuleSetRevision
        |> Ash.Query.filter(
          organization_id == ^changeset.data.organization_id and
            name == ^changeset.data.name and
            status == :active and
            id != ^changeset.data.id
        )
        |> Ash.read!(authorize?: false)

      Enum.each(predecessors, fn predecessor ->
        AshCompliance.Domain.retire_rule_set_revision!(predecessor,
          authorize?: false,
          as_of: instant
        )
      end)

      callback.(changeset)
    end)
  end

  # The action's pinned write instant (PinWriteInstant resolves the
  # effective_at argument or the house clock before this change runs).
  defp write_instant(changeset) do
    case changeset.as_of do
      instant when is_struct(instant, DateTime) -> instant
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end
end
