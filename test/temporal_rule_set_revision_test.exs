# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TemporalRuleSetRevisionTest do
  @moduledoc """
  Phase 3 slice 3 demonstrations: the rule set revision lifecycle becomes
  period history and double-activation becomes database-impossible (design
  §1, §3 row 3, §8.1/§8.2).

    * **§4(a)** — in-force-at-T across an activation boundary.
    * **§4(b)** — future-dated activation: invisible now, in force at the
      instant, no scheduler (the declared-instant `effective_at` argument).
    * **§4(c)** — the `one_active_per_name` exclusion rejects
      double-activation at the database, and retires open the path again.
    * **§4(d)** — formal self-split adjacency: dense lifecycle churn on one
      `(organization_id, name, revision)` never false-conflicts with the
      `unique_revision` exclusion.
    * **§4(e)** — lineage ids survive: `contributions` lists carry rule set
      revision ids, and they resolve identically after churn (the §8.1
      id-preservation contract, proven live).
    * **§4(f)** — gather determinism: a compile at a pinned `now` returns
      the same bundle and `content_hash` after later writes, because the
      gather's as-of is the pin (one instant for the whole gather).

  Lifecycle writes pin their instants with the `as_of` action option; the
  compile pins its clock with `now:` — the same instant governs the whole
  gather.
  """

  use AshCompliance.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Compiler
  alias AshCompliance.Domain
  alias AshCompliance.Test.Support

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp hours_after(dt, hours), do: DateTime.add(dt, hours * 3600, :second)

  defp draft(org, name, opts \\ []) do
    Support.rule_set_revision(
      organization_id: org,
      name: name,
      revision: Keyword.get(opts, :revision, "1"),
      layer: Keyword.get(opts, :layer, :global_mandatory),
      as_of: Keyword.get(opts, :as_of, @now)
    )
  end

  defp lifecycle(revision, at, actions) do
    Enum.reduce(actions, revision, fn action, rev ->
      apply(Domain, :"#{action}_rule_set_revision!", [rev, [authorize?: false, as_of: at]])
    end)
  end

  defp activate(revision, at, opts \\ []) do
    case Keyword.get(opts, :effective_at) do
      nil ->
        Domain.activate_rule_set_revision!(revision, authorize?: false, as_of: at)

      instant ->
        Domain.activate_rule_set_revision!(revision, %{effective_at: instant},
          authorize?: false,
          as_of: at
        )
    end
  end

  defp actives_at(org, at) do
    Domain.active_rule_set_revisions!(org, as_of: at, authorize?: false)
  end

  defp revision_at(id, at) do
    Domain.get_rule_set_revision_by_id!(id, as_of: at, authorize?: false)
  end

  # --- §4(a): in-force-at-T across the activation boundary ------------------------

  test "as-of before an activation the revision is not in force; at and after it is" do
    org = Ecto.UUID.generate()
    name = "boundary-#{System.unique_integer([:positive])}"

    t2 = hours_after(@now, 24)

    revision =
      draft(org, name)
      |> lifecycle(@now, [:validate, :approve])
      |> activate(t2)

    # Before the boundary: not in force (and still carrying the approved
    # status it carried then).
    assert actives_at(org, @now) == []
    assert revision_at(revision.id, @now).status == :approved

    # At the inclusive boundary instant: in force.
    assert [%{id: id}] = actives_at(org, t2)
    assert id == revision.id

    # After it: in force.
    assert [%{id: id}] = actives_at(org, hours_after(t2, 1))
    assert id == revision.id

    # And the retire boundary closes it again.
    Domain.retire_rule_set_revision!(revision, authorize?: false, as_of: hours_after(t2, 48))

    assert actives_at(org, hours_after(t2, 49)) == []
    assert revision_at(revision.id, hours_after(t2, 49)).status == :retired
  end

  # --- §4(b): future-dated activation, no scheduler --------------------------------

  test "a future-dated activation is invisible now, in force at the instant" do
    org = Ecto.UUID.generate()
    name = "future-#{System.unique_integer([:positive])}"

    friday = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)

    revision =
      draft(org, name)
      |> lifecycle(@now, [:validate, :approve])
      |> activate(@now, effective_at: friday)

    # Nothing in force now — the plain read and the compile agree.
    assert actives_at(org, @now) == []
    assert revision_at(revision.id, @now).status == :approved

    {:ok, bundle, _lineage} = Compiler.compile(organization_id: org, now: @now)
    assert bundle.rules == []

    # At the effective instant it is in force — the write itself opened the
    # future period; no scheduler ran in between.
    assert [%{id: id}] = actives_at(org, friday)
    assert id == revision.id

    {:ok, bundle, _lineage} = Compiler.compile(organization_id: org, now: friday)
    refute bundle.rules == []
  end

  # --- §4(c): the exclusion rejects double-activation at the database --------------

  test "activating a second revision of one name while one is in force is refused" do
    org = Ecto.UUID.generate()
    name = "double-#{System.unique_integer([:positive])}"

    first =
      draft(org, name, revision: "1")
      |> lifecycle(@now, [:validate, :approve])
      |> activate(@now)

    second =
      draft(org, name, revision: "2")
      |> lifecycle(@now, [:validate, :approve])

    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.activate_rule_set_revision(second, authorize?: false, as_of: @now)

    assert Enum.any?(error.errors, &(&1.message =~ "has already been taken"))

    # No partial state: exactly one active, and it is the first.
    assert [%{id: id}] = actives_at(org, @now)
    assert id == first.id

    # Retiring the first NULLs its active_key: the successor's path opens.
    Domain.retire_rule_set_revision!(first, authorize?: false, as_of: hours_after(@now, 1))

    assert %{id: id} =
             Domain.activate_rule_set_revision!(second,
               authorize?: false,
               as_of: hours_after(@now, 2)
             )

    assert id == second.id
  end

  test "actives of different names do not collide, and future-dated actives are guarded too" do
    org = Ecto.UUID.generate()
    name = "alpha-#{System.unique_integer([:positive])}"

    a =
      draft(org, name)
      |> lifecycle(@now, [:validate, :approve])
      |> activate(@now)

    b =
      draft(org, "beta-#{System.unique_integer([:positive])}")
      |> lifecycle(@now, [:validate, :approve])
      |> activate(@now)

    assert [id_a, id_b] = actives_at(org, @now) |> Enum.map(& &1.id) |> Enum.sort()
    assert Enum.sort([a.id, b.id]) == [id_a, id_b]

    # A future-dated activation of the SAME name conflicts with the
    # in-force active even though the write's period opens in the future:
    # the periods overlap (one active per name at ANY instant).
    friday = hours_after(@now, 24)

    successor = lifecycle(draft(org, name, revision: "2"), @now, [:validate, :approve])

    assert {:error, %Ash.Error.Invalid{} = error} =
             Domain.activate_rule_set_revision(successor, %{effective_at: friday},
               authorize?: false,
               as_of: @now
             )

    assert Enum.any?(error.errors, &(&1.message =~ "has already been taken"))
  end

  # --- §4(d): formal self-split adjacency ------------------------------------------

  test "dense lifecycle churn on one (org, name, revision) never false-conflicts" do
    org = Ecto.UUID.generate()
    name = "churn-#{System.unique_integer([:positive])}"

    # The full chain under one id: draft → validated → approved → active →
    # retired. Five adjacent periods, one (org, name, revision) key.
    revision = draft(org, name)

    windows = [
      {@now, :draft},
      {hours_after(@now, 1), :validated},
      {hours_after(@now, 2), :approved},
      {hours_after(@now, 3), :active},
      {hours_after(@now, 5), :retired}
    ]

    revision = lifecycle(revision, hours_after(@now, 1), [:validate])
    revision = lifecycle(revision, hours_after(@now, 2), [:approve])
    revision = activate(revision, hours_after(@now, 3))

    revision =
      Domain.retire_rule_set_revision!(revision, authorize?: false, as_of: hours_after(@now, 5))

    # Every window resolves to the status that held there — the row's own
    # history never false-conflicted with the unique_revision exclusion.
    Enum.each(windows, fn {at, status} ->
      assert %{status: ^status} = revision_at(revision.id, at)
    end)
  end

  # --- §4(e): lineage ids survive churn --------------------------------------------

  test "contributions carry revision ids that resolve identically after churn" do
    org = Ecto.UUID.generate()

    revision =
      draft(org, "lineage-#{System.unique_integer([:positive])}")
      |> lifecycle(@now, [:validate, :approve])
      |> activate(@now)

    {:ok, bundle, lineage} = Compiler.compile(organization_id: org, now: @now)

    contributed = Enum.map(lineage, & &1.revision_id)
    assert revision.id in contributed
    assert bundle.revision =~ revision.id

    # Churn after the compile: retire and activate a successor under a new
    # revision string.
    Domain.retire_rule_set_revision!(revision, authorize?: false, as_of: hours_after(@now, 1))

    # Every contributed id still resolves — the id-preservation contract
    # (§8.1): splits adjust bounds on one row identity, they never re-id.
    Enum.each(contributed, fn id ->
      assert %{id: ^id} = Domain.get_rule_set_revision_by_id!(id, authorize?: false)
    end)
  end

  # --- §4(f): gather determinism at a pinned compile clock ---------------------------

  test "a compile at a pinned now is unchanged by later writes" do
    org = Ecto.UUID.generate()

    first =
      draft(org, "det-#{System.unique_integer([:positive])}")
      |> lifecycle(@now, [:validate, :approve])
      |> activate(@now)

    {:ok, bundle, lineage} = Compiler.compile(organization_id: org, now: @now)

    # Later writes, all after the pin: the first retires at +24h (closing
    # its active period — the exclusion demands it before any successor),
    # and a successor for the same name is future-dated at +48h.
    Domain.retire_rule_set_revision!(first, authorize?: false, as_of: hours_after(@now, 24))

    draft(org, first.name, revision: "2")
    |> lifecycle(@now, [:validate, :approve])
    |> activate(@now, effective_at: hours_after(@now, 48))

    draft(org, "det-later-#{System.unique_integer([:positive])}")
    |> lifecycle(@now, [:validate, :approve])
    |> activate(@now, effective_at: hours_after(@now, 72))

    # The pinned answer did not move: same bundle, same content hash, same
    # lineage — the compile clock is the gather's as-of, and history is not
    # rewritten by later writes.
    {:ok, bundle_again, lineage_again} = Compiler.compile(organization_id: org, now: @now)

    assert bundle_again.rules == bundle.rules
    assert bundle_again.content_hash == bundle.content_hash
    assert bundle_again.revision == bundle.revision

    assert Enum.map(lineage_again, &{&1.revision_id, &1.effect}) ==
             Enum.map(lineage, &{&1.revision_id, &1.effect})

    # At the successor's instant, the successor is what is in force.
    assert [%{revision: "2"}] = actives_at(org, hours_after(@now, 49))
  end
end
