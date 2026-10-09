# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.RuleSetRevision.Changes.DeriveActiveKey do
  @moduledoc """
  Derives `active_key` — the null-when-inactive flag in the
  `one_active_per_name` non-overlap exclusion: `"active"` iff the row's
  status is `:active`, NULL otherwise.

  GiST equality (`WITH =`) never conflicts on NULLs, so non-active rows
  never collide in the exclusion and only genuinely-active rows can — the
  waiver `scope_key` trick **inverted** (`scope_key` is a non-null stand-in
  that keeps NULL-scoped rows conflicting; this goes NULL precisely so
  non-active rows don't). Runs on every create and update so the key can
  never drift from the status that owns it — the value a retired revision
  leaves behind must be NULL, or history would block every successor.

  Temporal-safe: reads one attribute and force-sets a string — no clock
  reads, no side effects, `as_of` untouched.
  """

  use Ash.Resource.Change

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if Ash.Changeset.get_attribute(changeset, :status) == :active do
        Ash.Changeset.force_change_attribute(changeset, :active_key, "active")
      else
        Ash.Changeset.force_change_attribute(changeset, :active_key, nil)
      end
    end)
  end
end
