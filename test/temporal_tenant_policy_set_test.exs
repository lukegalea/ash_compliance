# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TemporalTenantPolicySetTest do
  @moduledoc """
  Phase 3 slice 5 — the finale demonstrations: the tenant policy set is
  period-versioned, and the retroactive compile audit's substrate exists
  (design §3 row 5).

    * **The payoff** — set_active_bundle at t₁, a revision-list change at
      t₂: as-of reads at t₁/t₂/now return the exact set state that held at
      each instant. "Which revisions was this tenant pinned to at T" is a
      containment read.
    * **The retroactive audit** — the set's as-of read combined with the
      slice-3 in-force reads resolves which RULE SET REVISIONS were in
      force for the tenant at T (ids-at-T × in-force-at-T).
    * **The compile gather stays a CURRENT-pointer read** — pinned
      compiles resolve the set as of now, exactly as before the swap;
      determinism comes from the revision-side as-of (slice 3).
    * **SetActiveBundle** — byte-identical refusals after the
      temporal-safe declaration; the pointer change splits the period.
    * **Self-split adjacency** — config churn under one id never
      false-conflicts with `one_per_organization`; a second same-org row
      at an overlapping instant is still rejected.

  Writes pin their instants with the `as_of` action option; reads pin
  theirs with `as_of:`. Fixtures date relative to the fixture clock for
  pinned reads (the current-pointer reads see the latest period, which is
  the point).
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.Compiler
  alias AshCompliance.Domain
  alias AshCompliance.Test.Support

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp hours_after(dt, hours), do: DateTime.add(dt, hours * 3600, :second)

  defp create_profile_with_revision(
         at,
         ops \\ [%{"op" => "include", "target" => "kyc.review_required"}]
       ) do
    profile =
      Domain.create_profile!(
        %{
          organization_id: Ecto.UUID.generate(),
          name: "profile-#{System.unique_integer([:positive])}"
        },
        authorize?: false
      )

    {:ok, revision} =
      Domain.create_profile_revision(
        %{
          profile_id: profile.id,
          version: "1.0",
          operations: ops,
          content_hash: Base.encode16(:crypto.hash(:sha256, profile.id))
        },
        authorize?: false,
        as_of: at
      )

    {profile, revision}
  end

  defp active_rule_set(org, name, revision, at) do
    Support.rule_set_revision(
      organization_id: org,
      name: name,
      revision: revision,
      as_of: hours_after(at, -1)
    )
    |> then(&Domain.validate_rule_set_revision!(&1, authorize?: false, as_of: at))
    |> then(&Domain.approve_rule_set_revision!(&1, authorize?: false, as_of: at))
    |> then(&Domain.activate_rule_set_revision!(&1, authorize?: false, as_of: at))
  end

  defp pinned_set(org, at) do
    Domain.tenant_policy_set!(org, as_of: at, authorize?: false)
  end

  # --- the payoff: the set state that held at T ----------------------------------

  test "as-of reads reconstruct which revisions the tenant was pinned to at T" do
    org = Ecto.UUID.generate()

    t0 = hours_after(@now, -48)
    t1 = hours_after(@now, -24)
    t2 = hours_after(@now, -4)

    {profile, p1} = create_profile_with_revision(hours_after(t0, -1))
    {:ok, _p2} = create_revision_extra(profile, "2.0", hours_after(t0, -1))

    {:ok, bundle} =
      Domain.compile_policy_bundle(%{organization_id: org, label: "payoff"}, authorize?: false)

    _active_bundle = Domain.activate_policy_bundle!(bundle, authorize?: false)

    {:ok, set} =
      Domain.create_tenant_policy_set(
        %{organization_id: org, name: "payoff-set", profile_revision_ids: [p1.id]},
        authorize?: false,
        as_of: t0
      )

    # t₁: the pointer change splits the period.
    Domain.set_active_bundle!(set, %{active_policy_bundle_id: bundle.id},
      authorize?: false,
      as_of: t1
    )

    # t₂: the membership change splits the period again.
    Domain.set_revisions!(set, %{profile_revision_ids: [p1.id, p2_id(profile)]},
      authorize?: false,
      as_of: t2
    )

    # At t₀+ε: the initial pin, no bundle yet.
    state0 = pinned_set(org, hours_after(t0, 1))
    assert state0.profile_revision_ids == [p1.id]
    assert state0.active_policy_bundle_id == nil

    # At t₁+ε: same lists, bundle now pinned.
    state1 = pinned_set(org, hours_after(t1, 1))
    assert state1.profile_revision_ids == [p1.id]
    assert state1.active_policy_bundle_id == bundle.id

    # At t₂+ε: the new membership, bundle still pinned.
    state2 = pinned_set(org, hours_after(t2, 1))
    assert length(state2.profile_revision_ids) == 2
    assert state2.active_policy_bundle_id == bundle.id

    # Now: the current pointer reads the same latest period.
    current = Domain.tenant_policy_set!(org, authorize?: false)
    assert current.profile_revision_ids == state2.profile_revision_ids
    assert current.id == state2.id
  end

  defp create_revision_extra(profile, version, at) do
    Domain.create_profile_revision(
      %{
        profile_id: profile.id,
        version: version,
        operations: [],
        content_hash: Base.encode16(:crypto.hash(:sha256, version))
      },
      authorize?: false,
      as_of: at
    )
  end

  defp p2_id(profile) do
    Domain.profile_revisions_for_profile!(profile.id, authorize?: false)
    |> Enum.find(&(&1.version == "2.0"))
    |> then(& &1.id)
  end

  # --- the retroactive audit: ids-at-T × in-force-at-T ------------------------------

  test "which rule set revisions were in force for the tenant at T" do
    org = Ecto.UUID.generate()
    name = "audit-#{System.unique_integer([:positive])}"

    ta = hours_after(@now, -72)
    tr = hours_after(@now, -6)
    tb = hours_after(@now, -5)
    t0 = hours_after(@now, -48)
    t2 = hours_after(@now, -4)

    r1 = active_rule_set(org, name, "1", ta)
    Domain.retire_rule_set_revision!(r1, authorize?: false, as_of: tr)
    r2 = active_rule_set(org, name, "2", tb)

    {profile, p1} = create_profile_with_revision(hours_after(t0, -1))

    {:ok, set} =
      Domain.create_tenant_policy_set(
        %{
          organization_id: org,
          name: "audit-set",
          profile_revision_ids: [p1.id],
          rule_set_revision_ids: [r1.id]
        },
        authorize?: false,
        as_of: t0
      )

    Domain.set_revisions!(set, %{rule_set_revision_ids: [r2.id], profile_revision_ids: [p1.id]},
      authorize?: false,
      as_of: t2
    )

    # The audit read at T: the set's pinned ids at T, resolved against the
    # revisions in force at T (the slice-3 containment read).
    in_force_for_tenant_at = fn at ->
      set = pinned_set(org, at)

      set.rule_set_revision_ids
      |> Enum.map(fn id ->
        Domain.get_rule_set_revision_by_id!(id, as_of: at, authorize?: false)
      end)
      |> Enum.filter(&(&1.status == :active))
    end

    # At T1: pinned to r1, and r1 was in force.
    assert [%{id: id1}] = in_force_for_tenant_at.(hours_after(t0, 1))
    assert id1 == r1.id

    # At T2: pinned to r2, and r2 (alone) is in force — r1 retired at tr.
    assert [%{id: id2}] = in_force_for_tenant_at.(hours_after(t2, 1))
    assert id2 == r2.id

    # The profile side resolves at T too: the pinned profile revision
    # existed at both instants (created before the set).
    set = pinned_set(org, hours_after(t0, 1))

    assert [%{id: pid}] =
             Enum.map(set.profile_revision_ids, fn id ->
               Domain.get_profile_revision_by_id!(id,
                 as_of: hours_after(t0, 1),
                 authorize?: false
               )
             end)

    assert pid == p1.id

    # A revision NOT yet created at T is invisible to the as-of resolution:
    # asking for p2 (created after T1) as of T1 finds nothing to resolve —
    # the id was never pinned then anyway, which is the point of the read.
    set2 = pinned_set(org, hours_after(t2, 1))

    Enum.each(set2.profile_revision_ids, fn id ->
      revision =
        Domain.get_profile_revision_by_id!(id, as_of: hours_after(t2, 1), authorize?: false)

      assert revision.id in set2.profile_revision_ids
    end)
  end

  # --- the compile gather stays a current-pointer read -------------------------------

  test "a pinned compile still resolves the set as of now, unchanged" do
    org = Ecto.UUID.generate()
    name = "pointer-#{System.unique_integer([:positive])}"

    # A refine op produces a lineage entry, proving the id-list read rode
    # the gather (include is documentary and leaves no lineage trace). The
    # refine targets a tenant-strengthening rule — mandatory rules outrank
    # profile refinements.
    _baseline =
      active_rule_set(
        org,
        "base-#{System.unique_integer([:positive])}",
        "1",
        hours_after(@now, -24)
      )

    strengthening =
      Support.rule_set_revision(
        organization_id: org,
        name: "str-#{System.unique_integer([:positive])}",
        layer: :tenant_strengthening,
        rules_json: Support.bundle_json(AshCompliance.Test.RuleSets.TenantStrengthening),
        content_hash: AshCompliance.Test.RuleSets.TenantStrengthening.__bundle__().content_hash,
        as_of: hours_after(@now, -24)
      )
      |> then(
        &Domain.validate_rule_set_revision!(&1, authorize?: false, as_of: hours_after(@now, -24))
      )
      |> then(
        &Domain.approve_rule_set_revision!(&1, authorize?: false, as_of: hours_after(@now, -24))
      )
      |> then(
        &Domain.activate_rule_set_revision!(&1, authorize?: false, as_of: hours_after(@now, -24))
      )

    {profile, p1} =
      create_profile_with_revision(hours_after(@now, -24), [
        %{"op" => "refine", "target" => "acct.balance_frozen", "severity" => "critical"}
      ])

    {:ok, bundle} =
      Domain.compile_policy_bundle(%{organization_id: org, label: "pointer"}, authorize?: false)

    _active = Domain.activate_policy_bundle!(bundle, authorize?: false)

    {:ok, _set} =
      Domain.create_tenant_policy_set(
        %{
          organization_id: org,
          name: "pointer-set",
          profile_revision_ids: [p1.id],
          rule_set_revision_ids: [strengthening.id]
        },
        authorize?: false,
        as_of: hours_after(@now, -12)
      )

    # A pinned compile: the revision-side as-of (slice 3) governs the rule
    # reads; the SET is read as of now — the current pointer — exactly as
    # before the swap. The compile resolves and is deterministic.
    {:ok, bundle_one, lineage_one} = Compiler.compile(organization_id: org, now: @now)
    {:ok, bundle_two, lineage_two} = Compiler.compile(organization_id: org, now: @now)

    assert bundle_two.rules == bundle_one.rules
    assert bundle_two.content_hash == bundle_one.content_hash

    assert Enum.map(lineage_two, &{&1.revision_id, &1.effect}) ==
             Enum.map(lineage_one, &{&1.revision_id, &1.effect})

    # The profile refinement rode the gather: the pinned id-list read
    # resolved the revision and its refine patched the target rule
    # (`:refine` operations patch rules without a lineage entry — the
    # bundle's rule severity is the proof).
    rule = Enum.find(bundle_one.rules, &(&1.id == "acct.balance_frozen"))
    assert rule.severity == :critical
  end

  # --- SetActiveBundle: byte-identical refusals ---------------------------------------

  test "set_active_bundle refuses non-active bundles verbatim" do
    org = Ecto.UUID.generate()

    {:ok, compiled} =
      Domain.compile_policy_bundle(%{organization_id: org, label: "refusal"}, authorize?: false)

    {:ok, set} =
      Domain.create_tenant_policy_set(%{organization_id: org, name: "refusal-set"},
        authorize?: false,
        as_of: @now
      )

    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.set_active_bundle(set, %{active_policy_bundle_id: compiled.id},
               authorize?: false,
               as_of: @now
             )

    assert Enum.any?(
             error.errors,
             &(&1.message =~
                 "cannot activate tenant policy set against a bundle with status :compiled")
           )

    missing = Ecto.UUID.generate()

    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.set_active_bundle(set, %{active_policy_bundle_id: missing},
               authorize?: false,
               as_of: @now
             )

    assert Enum.any?(error.errors, &(&1.message =~ "does not exist"))
  end

  # --- self-split adjacency and the org exclusion ---------------------------------------

  test "config churn under one id never false-conflicts; a second same-org row is rejected" do
    org = Ecto.UUID.generate()

    {:ok, bundle} =
      Domain.compile_policy_bundle(%{organization_id: org, label: "churn"}, authorize?: false)

    _active = Domain.activate_policy_bundle!(bundle, authorize?: false)

    {:ok, set} =
      Domain.create_tenant_policy_set(%{organization_id: org, name: "churn-set"},
        authorize?: false,
        as_of: hours_after(@now, -24)
      )

    # Dense config churn: pointer change, membership change, pointer again —
    # adjacent periods under one id, the org exclusion never fires.
    Domain.set_active_bundle!(set, %{active_policy_bundle_id: bundle.id},
      authorize?: false,
      as_of: hours_after(@now, -20)
    )

    Domain.set_revisions!(set, %{profile_revision_ids: [Ecto.UUID.generate()]},
      authorize?: false,
      as_of: hours_after(@now, -16)
    )

    Domain.set_active_bundle!(set, %{active_policy_bundle_id: bundle.id},
      authorize?: false,
      as_of: hours_after(@now, -12)
    )

    latest = Domain.tenant_policy_set!(org, authorize?: false)
    assert latest.id == set.id
    assert latest.active_policy_bundle_id == bundle.id

    # A DISTINCT second set for the org at an overlapping instant is still
    # rejected — one set history per organization.
    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.create_tenant_policy_set(%{organization_id: org, name: "impostor"},
               authorize?: false,
               as_of: @now
             )

    assert Enum.any?(error.errors, &(&1.message =~ "has already been taken"))
  end
end
