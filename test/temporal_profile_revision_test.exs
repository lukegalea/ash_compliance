# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TemporalProfileRevisionTest do
  @moduledoc """
  Phase 3 slice 4 demonstrations: a profile revision's period opens at its
  creation and never ends (design §3 row 4 — create+read only, nothing
  splits it).

    * **§4(a)-style** — a revision is visible as-of after its creation,
      not before (pinned and plain reads agree at their own instants).
    * **latest_for_profile** — the containment read with preserved
      ordering: newest period-lower first; under `as_of`, the identical
      read answers "the latest revision as of T".
    * **§4(e) lineage** — `TenantPolicySet.profile_revision_ids` address
      revisions by id; the ids resolve identically pre/post swap (the
      §8.1 contract — this slice's compile semantics are unchanged: ids
      still point at rows, periods now ride along).
    * **ValidateOperations** — the one custom validation in the blast
      radius, now declared temporal-safe, keeps its byte-identical
      refusals.

  Boundary fixtures that must be invisible to the plain as-of-now read are
  dated relative to the real clock (the slice-1 lesson: an open-ended
  period opened in the fixture past already contains today).
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.Domain

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp hours_after(dt, hours), do: DateTime.add(dt, hours * 3600, :second)

  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

  defp create_profile do
    Domain.create_profile!(
      %{
        organization_id: Ecto.UUID.generate(),
        name: "profile-#{System.unique_integer([:positive])}"
      },
      authorize?: false
    )
  end

  defp create_revision(profile, version, opts \\ []) do
    Domain.create_profile_revision(
      %{
        profile_id: profile.id,
        version: version,
        source: "test",
        operations: Keyword.get(opts, :operations, []),
        content_hash: Base.encode16(:crypto.hash(:sha256, version))
      },
      Keyword.merge([authorize?: false], Keyword.take(opts, [:as_of]))
    )
  end

  defp latest_at(profile_id, at) do
    Domain.latest_profile_revision!(profile_id, as_of: at, authorize?: false)
  end

  # --- §4(a)-style: visible as-of after creation, not before ----------------------

  test "a revision is not visible as-of before its creation; visible at and after" do
    profile = create_profile()
    tomorrow = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)

    {:ok, revision} = create_revision(profile, "1.0", as_of: tomorrow)

    # Before the boundary: invisible to the pinned read and to the plain
    # (as-of-now) read alike.
    assert latest_at(profile.id, DateTime.utc_now()) == nil

    assert Domain.profile_revisions_for_profile!(profile.id,
             as_of: DateTime.utc_now(),
             authorize?: false
           ) == []

    # At the boundary instant itself (inclusive lower bound): visible.
    latest = Ash.load!(latest_at(profile.id, tomorrow), [:effective_from], authorize?: false)
    assert latest.id == revision.id
    assert same_instant?(latest.effective_from, tomorrow)

    # And after it.
    assert latest_at(profile.id, hours_after(tomorrow, 1)).id == revision.id
  end

  # --- latest is containment with preserved ordering --------------------------------

  test "latest_for_profile ranks by period-lower and travels backward under as_of" do
    profile = create_profile()

    t_early = hours_after(@now, -48)
    t_late = hours_after(@now, -24)

    # Created in the opposite order of their periods' lower bounds: the
    # row created LAST carries the EARLIER creation instant. The old
    # insertion-order convention would have ranked it first forever.
    {:ok, _late} = create_revision(profile, "2.0", as_of: t_late)
    {:ok, early} = create_revision(profile, "1.0", as_of: t_early)

    # As of the window where only the early revision exists, it is the
    # latest — insertion order would say otherwise.
    assert latest_at(profile.id, hours_after(t_early, 1)).id == early.id

    # At now, the later-created revision is the latest (both periods are
    # open-ended and contain the pin; greatest period-lower wins).
    assert latest_at(profile.id, @now).version == "2.0"
  end

  # --- identities under periods ------------------------------------------------------

  test "unique_revision still rejects a duplicate version for the profile" do
    profile = create_profile()

    {:ok, _first} = create_revision(profile, "1.0", as_of: @now)

    assert {:error, %Ash.Error.Invalid{} = error} =
             create_revision(profile, "1.0", as_of: hours_after(@now, 1))

    assert Enum.any?(error.errors, &(&1.message =~ "has already been taken"))
  end

  # --- §4(e): lineage ids resolve identically -----------------------------------------

  test "tenant_policy_set profile_revision_ids resolve identically after the swap" do
    org = Ecto.UUID.generate()
    profile = create_profile()

    {:ok, revision} =
      create_revision(profile, "1.0",
        as_of: @now,
        operations: [%{"op" => "include", "target" => "kyc.review_required"}]
      )

    {:ok, policy_set} =
      Domain.create_tenant_policy_set(
        %{organization_id: org, name: "lineage-set", profile_revision_ids: [revision.id]},
        authorize?: false
      )

    # The id-list still points at rows that resolve — with their periods
    # riding along. (The compiler's gather keeps reading these ids as
    # plain as-of-now gets this slice; slice 5 owns its temporal surface.)
    assert policy_set.profile_revision_ids == [revision.id]

    [resolved] =
      Enum.map(policy_set.profile_revision_ids, fn id ->
        Domain.get_profile_revision_by_id!(id, authorize?: false)
      end)

    assert resolved.id == revision.id
    assert resolved.content_hash == revision.content_hash
    assert resolved.valid_at.upper == nil
  end

  # --- the refactored validation keeps its refusals ------------------------------------

  test "ValidateOperations still refuses approval-bearing operations verbatim" do
    profile = create_profile()

    assert {:error, %Ash.Error.Invalid{} = error} =
             create_revision(profile, "1.0",
               operations: [%{"op" => "waive", "target" => "kyc.review_required"}]
             )

    assert Enum.any?(error.errors, &(&1.message =~ "waive is an approval-bearing operation"))
  end
end
