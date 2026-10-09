# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TemporalControlRevisionTest do
  @moduledoc """
  Phase 3 slice 2 demonstrations: a control revision's lifecycle becomes
  period history (design §1, §3 row 2 as amended by §8.2 — containment
  reads only, no single-active exclusion).

    * **The period records when each status held** — activate/withdraw
      split the period; as-of reads return what we believed at T, and the
      row's own adjacent splits never false-conflict with the
      `unique_revision` exclusion.
    * **§4(a): in-force-at-T across an activation boundary** — as-of
      before the activation the revision is not in force (the draft is
      still there, as a draft); at and after the boundary it is.
    * **§4(f): determinism at pinned instants** — the containment read's
      answer is a function of the pin alone, stable across later writes.
    * **§8.2: as-of-now ≡ today's `hd` answer with two actives present** —
      the drift the ruling preserves: repeated imports leave several
      actives; newest period-lower first puts the same revision at the
      head the old `inserted_at` ordering did, so the export consumer is
      byte-identical.

  Lifecycle writes pin their instants with the `as_of` action option (the
  tests play the host's clock; no DSL change — plain lifecycle writes
  still split at wall-now). Boundary fixtures that must be invisible to
  the plain as-of-now read are dated relative to the real clock (the
  slice-1 lesson: a past-dated open-ended period already contains today).
  """

  use AshCompliance.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Domain

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp hours_after(dt, hours), do: DateTime.add(dt, hours * 3600, :second)

  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

  defp create_control(org \\ Ecto.UUID.generate()) do
    Domain.create_control!(
      %{
        organization_id: org,
        control_id: "kyc.#{System.unique_integer([:positive])}"
      },
      authorize?: false
    )
  end

  defp create_revision(control, version, opts) do
    Domain.create_control_revision!(
      %{
        control_id: control.id,
        version: version,
        statement: opts[:statement] || "revision #{version}",
        status: Keyword.get(opts, :status, :draft)
      },
      authorize?: Keyword.get(opts, :authorize?, false),
      as_of: Keyword.get(opts, :as_of, @now)
    )
  end

  defp activate(revision, at) do
    Domain.activate_control_revision(revision, as_of: at, authorize?: false)
  end

  defp withdraw(revision, at) do
    Domain.withdraw_control_revision(revision, as_of: at, authorize?: false)
  end

  defp actives_at(control_id, at) do
    # The domain interface (what export calls), pinned.
    Domain.active_control_revisions!(control_id, as_of: at, authorize?: false)
  end

  defp revision_at(revision_id, at) do
    Domain.get_control_revision_by_id!(revision_id, as_of: at, authorize?: false)
  end

  # --- the period records when each status held ---------------------------------

  test "activate and withdraw split the period; as-of reads return the status at T" do
    control = create_control()

    t0 = hours_after(@now, -48)
    t2 = hours_after(@now, -24)
    t3 = hours_after(@now, -1)

    revision = create_revision(control, "1.0", as_of: t0)
    activate(revision, t2)
    withdraw(revision, t3)

    # One id, three adjacent status periods — the split-writes never
    # false-conflicted with the unique_revision exclusion (adjacent
    # half-open periods don't overlap).
    assert same_instant?(revision_at(revision.id, t0).valid_at.lower, t0)
    assert revision_at(revision.id, hours_after(t0, 1)).status == :draft
    assert revision_at(revision.id, hours_after(t2, 1)).status == :active
    assert revision_at(revision.id, hours_after(t3, 1)).status == :withdrawn

    # "In force at T" is the containment read across the same boundaries.
    assert actives_at(control.id, hours_after(t2, -1)) == []
    assert [%{id: id}] = actives_at(control.id, hours_after(t2, 1))
    assert id == revision.id
    assert actives_at(control.id, hours_after(t3, 1)) == []

    # The active status took hold at the activation instant, not at
    # insertion: effective_from is the period's lower bound.
    active = revision_at(revision.id, hours_after(t2, 1)) |> Ash.load!(:effective_from)
    assert same_instant?(active.effective_from, t2)
  end

  # --- §4(a): in-force-at-T across the activation boundary ------------------------

  test "as-of before an activation the revision is not in force; at and after it is" do
    control = create_control()
    tomorrow = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)

    revision = create_revision(control, "1.0", as_of: DateTime.utc_now())
    activate(revision, tomorrow)

    # Before the boundary (the real now): not in force — and the revision
    # itself is still there, carrying the draft it carried then.
    assert actives_at(control.id, DateTime.utc_now()) == []
    assert revision_at(revision.id, DateTime.utc_now()).status == :draft

    # At the boundary instant (inclusive lower bound): in force.
    assert [%{id: id}] = actives_at(control.id, tomorrow)
    assert id == revision.id

    # And after it.
    assert [%{id: id}] = actives_at(control.id, hours_after(tomorrow, 1))
    assert id == revision.id
  end

  # --- §4(f): determinism of the containment read at pinned instants ---------------

  test "the pinned containment read is stable across later writes and re-reads" do
    control = create_control()

    t0 = hours_after(@now, -72)
    t2 = hours_after(@now, -48)
    t3 = hours_after(@now, -24)

    revision = create_revision(control, "1.0", as_of: t0)
    activate(revision, t2)

    # Pinned in the draft window: empty. Pinned in the active window: the
    # revision. Re-reads at the same pin agree.
    assert actives_at(control.id, hours_after(t0, 1)) == []
    assert [%{id: id}] = actives_at(control.id, hours_after(t2, 1))
    assert id == revision.id

    # A withdrawal and an unrelated new revision land afterwards.
    withdraw(revision, t3)
    create_revision(control, "2.0", as_of: hours_after(t3, 1), status: :active)

    # Neither later write moved the earlier pinned answers: history is not
    # rewritten — the property a deterministic compile clock needs.
    assert actives_at(control.id, hours_after(t0, 1)) == []
    assert actives_at(control.id, hours_after(t2, 1)) |> Enum.map(& &1.id) == [revision.id]
    assert actives_at(control.id, hours_after(t2, 1)) |> Enum.map(& &1.id) == [revision.id]

    # After the withdrawal instant, the old active is out of force and the
    # new active (effective later) is the only one.
    assert [%{version: "2.0"}] = actives_at(control.id, hours_after(t3, 2))
  end

  # --- §8.2: as-of-now ≡ today's hd answer, multi-active preserved -----------------

  test "with two actives present, as-of-now puts the newest at the head, as hd did" do
    control = create_control()

    t_older = hours_after(@now, -48)
    t_newer = hours_after(@now, -24)

    # The import pattern: revisions created directly :active, the prior
    # active never closed. Created in this order, today's inserted_at
    # ordering heads with the newer — the containment read must agree.
    _older = create_revision(control, "1.0", as_of: t_older, status: :active)
    newer = create_revision(control, "2.0", as_of: t_newer, status: :active)

    actives = actives_at(control.id, @now)

    # Both actives are in force now (multi-active is preserved) ...
    assert Enum.map(actives, & &1.version) == ["2.0", "1.0"]

    # ... newest period-lower first, so the export's hd consumer sees the
    # same revision the old inserted_at ordering gave it. Byte-identical.
    assert hd(actives).id == newer.id

    # The same read pinned between the two publications sees only the
    # older active — the answer travels backward correctly.
    assert [%{version: "1.0"}] = actives_at(control.id, hours_after(t_older, 1))
  end

  # --- guards and identities ride the split path -----------------------------------

  test "activating a non-draft is refused with the exact message" do
    control = create_control()

    revision = create_revision(control, "1.0", status: :active)

    assert {:error, %Ash.Error.Invalid{} = error} = activate(revision, @now)

    assert Enum.any?(
             error.errors,
             &(&1.message =~ "only a draft control revision can be activated")
           )
  end

  test "a duplicate (control_id, version) at an overlapping instant is still rejected" do
    control = create_control()

    create_revision(control, "1.0", as_of: @now)

    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.create_control_revision(
               %{
                 control_id: control.id,
                 version: "1.0",
                 statement: "a duplicate"
               },
               authorize?: false,
               as_of: hours_after(@now, 1)
             )

    assert Enum.any?(error.errors, &(&1.message =~ "has already been taken"))
  end
end
