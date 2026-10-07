# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TemporalWaiverTest do
  @moduledoc """
  Phase 3 demonstrations: the waiver's in-force window is a temporal period
  (strategy memo Phase 3, ADR 0049).

    * **Non-overlap is DB-enforced** — a second waiver for the same
      (organization, rule, scope) while one is in force is rejected by the
      `WITHOUT OVERLAPS` exclusion. The double-granted waiver, previously
      possible by convention, is now impossible: the headline.
    * **Future-dating** — a waiver granted as of a future instant is
      invisible now and in force then, with no scheduler.
    * **As-of reads across the window** — the compiler's pinned-clock read
      (`valid_for_organization/2`) sees exactly the waivers whose enforced
      period contains the pinned instant, on the half-open `[starts,
      expires)` boundaries the old hand-rolled filter expressed.
    * **Split-write races converge or fail clean** — the concurrency story
      (`AshPostgres.Temporal.WriteConflict`) holds on this resource too.
  """

  use AshCompliance.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Resources.PolicyOverride
  alias AshCompliance.Test.Support

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp hours_after(dt, hours), do: DateTime.add(dt, hours * 3600, :second)

  # Period bounds round-trip through tstzrange with full microsecond
  # precision, so compare instants, not struct representations.
  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

  defp grant_waiver(rule_id, opts) do
    AshCompliance.Domain.create_policy_override(
      %{
        organization_id: Keyword.get(opts, :organization_id, Ecto.UUID.generate()),
        kind: :waive,
        rule_id: rule_id,
        reason: "documented operational exception",
        approver: "security-officer",
        approved_at: @now,
        starts_at: Keyword.get(opts, :starts_at, @now),
        expires_at: Keyword.get(opts, :expires_at, hours_after(@now, 24)),
        scope_subject_type: opts[:scope_subject_type],
        scope_subject_id: opts[:scope_subject_id],
        compensating_controls: ["manual-review"]
      },
      authorize?: false
    )
  end

  # The window a single in-force grant actually landed as, read back
  # through the derived calculations (the period's bounds).
  defp in_force_at(organization_id, rule_id, at) do
    PolicyOverride
    |> Ash.Query.filter(organization_id == ^organization_id and rule_id == ^rule_id)
    |> Ash.Query.as_of(at)
    |> Ash.read_one!(authorize?: false, load: [:starts_at, :expires_at])
  end

  defp valid_for(organization_id, now) do
    AshCompliance.Domain.valid_policy_overrides!(organization_id, now, authorize?: false)
  end

  # --- the period IS the in-force window ---------------------------------------

  test "a bounded grant lands as the half-open [starts_at, expires_at) period" do
    org = Ecto.UUID.generate()

    {:ok, waiver} = grant_waiver("kyc.review_required", organization_id: org)

    # The period: half-open, lower inclusive, upper exclusive — the same
    # boundary semantics the old read filter expressed by hand.
    assert same_instant?(waiver.valid_at.lower, @now)
    assert same_instant?(waiver.valid_at.upper, hours_after(@now, 24))
    assert waiver.valid_at.bounds == :"[)"

    # In force at the lower bound; out of force AT the upper bound.
    assert in_force_at(org, "kyc.review_required", @now)
    assert in_force_at(org, "kyc.review_required", hours_after(@now, 23))
    refute in_force_at(org, "kyc.review_required", hours_after(@now, 24))

    # The declared window survives as the derived plain reads.
    waiver = Ash.load!(waiver, [:starts_at, :expires_at], authorize?: false)
    assert same_instant?(waiver.starts_at, @now)
    assert same_instant?(waiver.expires_at, hours_after(@now, 24))
  end

  test "an evergreen replacement carries an open period, expires_at reads nil" do
    org = Ecto.UUID.generate()

    {:ok, replacement} =
      AshCompliance.Domain.create_policy_override(
        %{
          organization_id: org,
          kind: :replace,
          rule_id: "kyc.welcome_review",
          reason: "equivalent local control",
          approver: "security-officer",
          approved_at: @now,
          replacement_rules_json:
            Support.bundle_json(AshCompliance.Test.RuleSets.TenantSupplement),
          compensating_controls: []
        },
        authorize?: false
      )

    # An undated grant's period opens at the WRITE instant (the pinned
    # now of the write itself) and never ends: evergreen.
    assert DateTime.diff(DateTime.utc_now(), replacement.valid_at.lower) < 60
    assert replacement.valid_at.upper == nil

    replacement = Ash.load!(replacement, [:expires_at], authorize?: false)
    assert replacement.expires_at == nil
  end

  # --- the headline: non-overlap is DB-enforced ---------------------------------

  test "a second overlapping waiver for the same rule and scope is rejected" do
    org = Ecto.UUID.generate()

    {:ok, _first} = grant_waiver("kyc.review_required", organization_id: org)

    # Overlapping window, same (org, rule, scope): the double-granted
    # waiver. The database's exclusion constraint refuses it — this used
    # to be possible.
    assert {:error, %Ash.Error.Invalid{} = error} =
             grant_waiver("kyc.review_required",
               organization_id: org,
               starts_at: hours_after(@now, 1),
               expires_at: hours_after(@now, 30)
             )

    assert Enum.any?(error.errors, &(&1.message =~ "has already been taken"))

    # No partial state: exactly one waiver in force, and it is the first.
    assert in_force_at(org, "kyc.review_required", @now)
    assert org |> valid_for(@now) |> length() == 1
  end

  test "successive non-overlapping waivers are history, not overlap" do
    org = Ecto.UUID.generate()

    {:ok, first} =
      grant_waiver("kyc.review_required",
        organization_id: org,
        starts_at: hours_after(@now, -48),
        expires_at: hours_after(@now, -1)
      )

    # Starts exactly where the first ended: adjacent, not overlapping.
    assert {:ok, second} =
             grant_waiver("kyc.review_required",
               organization_id: org,
               starts_at: hours_after(@now, -1),
               expires_at: hours_after(@now, 24)
             )

    assert first.id != second.id
    assert in_force_at(org, "kyc.review_required", hours_after(@now, -24)).id == first.id
    assert in_force_at(org, "kyc.review_required", @now).id == second.id
  end

  test "scope-varying waivers for the same rule do not collide" do
    org = Ecto.UUID.generate()

    {:ok, _org_wide} =
      grant_waiver("kyc.review_required", organization_id: org)

    assert {:ok, _subject_scoped} =
             grant_waiver("kyc.review_required",
               organization_id: org,
               scope_subject_type: "customer",
               scope_subject_id: "cust-42"
             )

    # Two waivers, different scopes — no double-grant, no collision.
    assert org |> valid_for(@now) |> length() == 2
  end

  test "concurrent grants race to one winner and the losers fail clean" do
    org = Ecto.UUID.generate()

    outcomes =
      1..12
      |> Task.async_stream(
        fn _ ->
          try do
            case grant_waiver("kyc.review_required", organization_id: org) do
              {:ok, _} -> :granted
              {:error, %Ash.Error.Invalid{} = e} -> {:rejected, e}
            end
          rescue
            e in Ash.Error.Invalid -> {:rejected, e}
          end
        end,
        max_concurrency: 12,
        timeout: 60_000
      )
      |> Enum.map(fn
        {:ok, outcome} -> outcome
        {:exit, reason} -> {:exit, reason}
      end)

    assert Enum.filter(outcomes, &(&1 == :granted)) |> length() == 1

    # Every loser is the clean rejection — the exclusion surfaced as the
    # identity's InvalidAttribute, never a raw constraint crash.
    Enum.each(outcomes, fn
      {:rejected, error} ->
        assert Enum.any?(error.errors, &(&1.message =~ "has already been taken"))

      {:exit, reason} ->
        flunk("a racing grant exited: #{inspect(reason)}")

      _other ->
        :ok
    end)

    # Exactly one waiver in force for the key.
    assert org |> valid_for(@now) |> length() == 1
  end

  # --- future-dating: no scheduler ------------------------------------------------

  test "a waiver granted as of a future instant is invisible now, in force then" do
    org = Ecto.UUID.generate()
    friday = hours_after(@now, 24 * 7)

    {:ok, waiver} =
      grant_waiver("kyc.review_required",
        organization_id: org,
        starts_at: friday,
        expires_at: hours_after(friday, 24 * 7)
      )

    # The grant ran; nothing is in force now.
    assert valid_for(org, @now) == []

    # ...and the plain read (the state at now) does not see it either.
    assert PolicyOverride
           |> Ash.Query.filter(organization_id == ^org)
           |> Ash.read!(authorize?: false) == []

    # At the effective instant it is in force, with no scheduler in
    # between — the write itself opened the future period.
    assert [in_force] = valid_for(org, friday)
    assert in_force.id == waiver.id
    assert same_instant?(in_force.valid_at.lower, friday)
  end

  # --- as-of reads across the window ----------------------------------------------

  test "the pinned-clock read sees exactly the waivers in force at the pin" do
    org = Ecto.UUID.generate()

    # A backdated waiver that has already lapsed relative to @now.
    {:ok, _lapsed} =
      grant_waiver("kyc.review_required",
        organization_id: org,
        starts_at: hours_after(@now, -48),
        expires_at: hours_after(@now, -1)
      )

    # A waiver in force now (a full day's window around the pin).
    {:ok, _current} =
      grant_waiver("kyc.jurisdiction_required",
        organization_id: org,
        expires_at: hours_after(@now, 72)
      )

    # A future-dated waiver.
    {:ok, _future} =
      grant_waiver("kyc.valid_required",
        organization_id: org,
        starts_at: hours_after(@now, 48),
        expires_at: hours_after(@now, 96)
      )

    # At the pinned now: only the current one. The lapsed waiver's period
    # ended before the pin; the future one's begins after it.
    assert [only] = valid_for(org, @now)
    assert only.rule_id == "kyc.jurisdiction_required"

    # One instant earlier, inside the lapsed waiver's window, it is the
    # one in force (the current waiver has not started yet).
    rule_ids_at = fn at -> org |> valid_for(at) |> Enum.map(& &1.rule_id) |> Enum.sort() end

    assert rule_ids_at.(hours_after(@now, -24)) == ["kyc.review_required"]

    # Inside both the current and the future waiver's windows, both are in
    # force — different rules may legitimately overlap.
    assert rule_ids_at.(hours_after(@now, 49)) == [
             "kyc.jurisdiction_required",
             "kyc.valid_required"
           ]

    # And the compiler's pinned-clock determinism rides the same read:
    # nothing about the wall clock leaked into it.
    assert length(valid_for(org, @now)) == 1
  end

  # --- split-write races: converge, or fail with the clean WriteConflict ----------

  test "concurrent lapses of one evergreen replacement converge or fail clean" do
    org = Ecto.UUID.generate()
    lapse_at = hours_after(@now, 1)

    {:ok, replacement} =
      AshCompliance.Domain.create_policy_override(
        %{
          organization_id: org,
          kind: :replace,
          rule_id: "kyc.welcome_review",
          reason: "equivalent local control",
          approver: "security-officer",
          approved_at: @now,
          replacement_rules_json:
            Support.bundle_json(AshCompliance.Test.RuleSets.TenantSupplement),
          compensating_controls: []
        },
        # Written as of the fixture clock: an undated grant opens its
        # period at the write instant, and this test's reads pin @now.
        as_of: @now,
        authorize?: false
      )

    # Sixteen operators lapse the same replacement at the same instant:
    # sixteen concurrent split-writes (destroys as of `lapse_at`) on one
    # version. The engine locks, gates and retries internally; a writer
    # that exhausts its 25 attempts surfaces the clean
    # AshPostgres.Temporal.WriteConflict.
    outcomes =
      1..16
      |> Task.async_stream(
        fn _ ->
          try do
            replacement
            |> Ash.Changeset.for_destroy(:destroy, %{},
              as_of: lapse_at,
              authorize?: false
            )
            |> Ash.destroy!()

            :lapsed
          rescue
            e in AshPostgres.Temporal.WriteConflict -> {:conflict, e}
            e in Ash.Error.Invalid -> {:stale, e}
          end
        end,
        max_concurrency: 16,
        timeout: 120_000
      )
      |> Enum.map(fn
        {:ok, outcome} -> outcome
        {:exit, reason} -> {:exit, reason}
      end)

    # Nobody crashed; every outcome is one of the three clean endings.
    Enum.each(outcomes, fn
      {:exit, reason} -> flunk("a concurrent lapse exited: #{inspect(reason)}")
      {:conflict, e} -> assert e.resource == PolicyOverride
      {:stale, _} -> :ok
      :lapsed -> :ok
    end)

    # The period physically ends at the lapse instant (exclusive), one
    # version survives, and the replacement is still in force now.
    [in_force] = valid_for(org, @now)
    assert in_force.id == replacement.id
    assert same_instant?(in_force.valid_at.upper, lapse_at)

    refute in_force_at(org, "kyc.welcome_review", hours_after(@now, 2))
  end
end
