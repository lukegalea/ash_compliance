# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.RuleSetRevision.Changes.PinWriteInstant do
  @moduledoc """
  Pins the write instant for every create and lifecycle update, in one
  precedence order:

    1. An explicit `as_of` (action option / `Ash.Changeset.as_of/2`) — the
      caller's declared instant, untouched.
    2. `activate`'s `effective_at` argument (the waiver form, §1) — a
      future-dated activation is invisible now, in force from the instant,
      no scheduler.
    3. The house clock: wall-now **truncated to seconds** — the compile
      clock's convention (`compiler.ex`), and `inserted_at`'s actual
      column granularity.

  The default matters: the engine would otherwise pin a full-precision
  instant, and the compiler's clock is seconds-truncated — an activation at
  `10:00:00.600` would be invisible to a compile at `10:00:00` (its clock
  floors *below* the period's lower bound), so `activate → compile` in the
  same second — the editor's, the clinic's and the tests' path — would race.
  Aligning the write to the read clock's granularity makes a same-second
  lifecycle chain land inside the same compile instant. Sub-second
  history collapses into the second it happened in: for lifecycle chains
  that is exactly the truth the records can express anyway.

  Temporal-safe: resolves the write instant from the changeset, an argument,
  or the clock, and pins it as the changeset's `as_of` — no other effect.
  """

  use Ash.Resource.Change

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    cond do
      effective_at = Ash.Changeset.get_argument(changeset, :effective_at) ->
        Ash.Changeset.as_of(changeset, effective_at)

      engine_pinned?(changeset) ->
        Ash.Changeset.as_of(changeset, house_clock())

      true ->
        changeset
    end
  end

  # The engine pre-pins an undeclared temporal write during changeset setup
  # (`Ash.Changeset.pin_temporal_write_now/1`) and eagerly resolves it to a
  # full-precision wall instant, stamping `context.private.temporal_recorded_at`
  # as the marker of an engine-defaulted pin. A caller-declared `as_of`
  # (action option or `Ash.Changeset.as_of/2`) never sets that marker, so it
  # is the discriminator: engine pin → re-pin at the house clock; declared →
  # untouched. The atom/nil checks are a belt for upstream drift (if the
  # resolution ever becomes lazy, the `:now` atom reappears and is still
  # "undeclared"). This marker is an implementation detail — the upstream
  # sharp edge (no public way to distinguish an engine-pinned instant from a
  # declared one at change phase) is noted in the slice PR.
  defp engine_pinned?(changeset) do
    changeset.as_of in [nil, :now] or
      Map.has_key?(changeset.context[:private] || %{}, :temporal_recorded_at)
  end

  defp house_clock, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
