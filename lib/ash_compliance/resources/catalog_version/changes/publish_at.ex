# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.CatalogVersion.Changes.PublishAt do
  @moduledoc """
  Maps the publication's declared instant onto the temporal period.

  The `published_at` argument → the write's `as_of`: the create opens the
  period there — the past for a backdated publication (reconstructing
  history), the future for a future-dated one (invisible now, in force from
  that instant, no scheduler). Absent, the write stays pinned to now: the
  version is published the moment it is written, which is what the old
  `published_at: now()` import default expressed.

  Versions are append-only — there is no upper bound to apply, unlike the
  waiver's `BoundWindow`; the period is evergreen by construction.

  Temporal-safe: resolves the write instant from an argument and pins it as
  the changeset's `as_of` — no wall-clock reads, no present-tense side
  effects.
  """

  use Ash.Resource.Change

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :published_at) do
      nil -> changeset
      published_at -> Ash.Changeset.as_of(changeset, published_at)
    end
  end
end
