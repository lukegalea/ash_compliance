# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyOverride.Changes.DeriveScopeKey do
  @moduledoc """
  Derives `scope_key` — the non-null stand-in for the nullable
  `(scope_subject_type, scope_subject_id)` pair in the
  `one_in_force_per_scope` non-overlap exclusion.

  GiST equality (`WITH =`) never conflicts on NULLs, so keying the
  exclusion directly on the scope columns would leave organization-wide
  waivers (both scopes nil) unconstrained — exactly the double-grant the
  exclusion exists to kill. nil scopes hash to the empty element, so
  "organization-wide" keys deterministically; the same derivation runs in
  the temporal migration's backfill (unit-separator concat), so backfilled
  rows and new grants under the same scope always share one key.

  Temporal-safe: reads two attributes and force-sets a string — no clock
  reads, no side effects, `as_of` untouched.
  """

  use Ash.Resource.Change

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Ash.Changeset.force_change_attribute(changeset, :scope_key, scope_key(changeset))
    end)
  end

  # `<type>\x1F<id>`, nils as empty elements. The unit separator cannot be
  # part of a sane scope id, and the derivation is mirrored verbatim in the
  # migration's SQL backfill (`coalesce(...) || E'\\x1f' || coalesce(...)`).
  def scope_key(changeset) do
    [
      Ash.Changeset.get_attribute(changeset, :scope_subject_type) || "",
      Ash.Changeset.get_attribute(changeset, :scope_subject_id) || ""
    ]
    |> Enum.join(<<0x1F>>)
  end
end
