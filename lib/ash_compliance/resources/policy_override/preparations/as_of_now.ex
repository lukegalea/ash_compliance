# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyOverride.Preparations.AsOfNow do
  @moduledoc """
  Pins the `valid_for_organization` read to its `now` argument: the pinned
  instant becomes the query's `as_of`, so the database answers with the
  overrides whose enforced period contains that instant (index-backed
  containment on `valid_at`).

  This is the temporal reading of the old hand-rolled in-force filter
  (`starts_at <= now` and `is_nil(expires_at) or expires_at > now`) and it
  is what keeps the compiler's deterministic compile clock working: the
  compile passes its pinned `now` and sees exactly the waivers in force at
  that instant — no wall clock anywhere in the read.

  Temporal-safe: pure query work from an argument; `as_of` is the very
  thing it sets.
  """

  use Ash.Resource.Preparation

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.as_of(query, Ash.Query.get_argument(query, :now))
  end
end
