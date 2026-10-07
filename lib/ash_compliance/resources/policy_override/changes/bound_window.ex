# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyOverride.Changes.BoundWindow do
  @moduledoc """
  Maps the grant's declared window onto the temporal period.

    * `starts_at` argument → the write's `as_of`: the create opens the
      period there — the future for a future-dated waiver, the past for a
      backdated one (absent, the write stays pinned to now).
    * `expires_at` argument → an in-transaction truncate (`destroy` as of
      that instant) cuts the just-opened `[as_of, ∞)` down to
      `[starts_at, expires_at)`. The bound is physical: after the grant
      there is no version in force past `expires_at`, so expiry needs no
      scheduler and can never drift from storage. The truncate is the
      mechanical second half of the same grant the caller already
      authorized, so it runs `authorize?: false` on purpose (the package's
      trusted-machinery convention).

  An absent `expires_at` (an evergreen `:replace`) leaves the create's
  unbounded period standing.

  Temporal-safe: resolves the write instant from an argument, and its only
  effect is a same-transaction Ash destroy pinned to an explicit `as_of` —
  no wall-clock reads, no present-tense side effects.
  """

  use Ash.Resource.Change

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    changeset = apply_starts_at(changeset)

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      case Ash.Changeset.get_argument(changeset, :expires_at) do
        nil ->
          {:ok, record}

        expires_at ->
          {:ok, truncate(record, expires_at)}
      end
    end)
  end

  defp apply_starts_at(changeset) do
    case Ash.Changeset.get_argument(changeset, :starts_at) do
      nil -> changeset
      starts_at -> Ash.Changeset.as_of(changeset, starts_at)
    end
  end

  defp truncate(record, expires_at) do
    record
    |> Ash.Changeset.for_destroy(:destroy, %{}, as_of: expires_at, authorize?: false)
    |> Ash.destroy!()

    surviving_version(record)
  end

  # The destroy truncated the version in force at `expires_at` down to its
  # lower bound. Re-read as of the grant's own instant to hand back the row
  # that actually exists afterwards: the bounded
  # `[starts_at, expires_at)` version. A bounded grant always keeps its
  # opening version — the waiver-bounds validation refuses an `expires_at`
  # at or before the period's lower bound, so nothing can truncate the
  # window out from under the row this action just wrote. (And if a
  # stale-write refusal ever did escape the truncate, the after_action
  # failure rolls the whole grant back — no unbounded partial state.)
  defp surviving_version(record) do
    AshCompliance.Resources.PolicyOverride
    |> Ash.Query.filter(id == ^record.id)
    |> Ash.Query.as_of(record.valid_at.lower)
    |> Ash.read_one!(authorize?: false)
  end
end
