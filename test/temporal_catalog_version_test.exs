# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TemporalCatalogVersionTest do
  @moduledoc """
  Phase 3 slice 1 demonstrations: a catalog version's publication window is
  a temporal period (design §3 row 1, the waiver-move pattern from
  `PolicyOverride`).

    * **The period IS the publication window** — `[published_at, ∞)`, the
      name surviving as a `range_lower` calculation that filters at the
      data layer.
    * **In-force-at-T across the publication boundary** (design §4a) —
      as-of before the publication the version does not exist; as-of after,
      it does. No scheduler, no status column: containment.
    * **Gather determinism at pinned `now`** (design §4f, resource-level) —
      the compiler's gather (`compiler.ex`) threads its pinned `now` only
      through the override/revision reads, not through `CatalogVersion` (it
      never reads versions — grep-verified), so the catalog read path the
      compiler could ever use is `latest_for_catalog`; this suite pins
      instants and proves that read's answers are functions of the pin
      alone, stable across later writes and re-reads.
    * **Latest is containment, not insertion order** — a backdated
      publication ranks by publication instant, which the old
      `inserted_at`-desc convention got wrong.
    * **Identities still fire** — `unique_version`/`unique_hash` are
      period-aware (`WITHOUT OVERLAPS`) and reject overlapping same-keyed
      writes exactly as the old plain unique indexes did.
  """

  use AshCompliance.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Domain
  alias AshCompliance.Resources.CatalogVersion

  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp hours_after(dt, hours), do: DateTime.add(dt, hours * 3600, :second)

  # Period bounds round-trip through tstzrange with full microsecond
  # precision, so compare instants, not struct representations.
  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

  defp create_catalog(org \\ Ecto.UUID.generate()) do
    Domain.create_catalog!(
      %{
        organization_id: org,
        name: "KYC Baseline #{System.unique_integer([:positive])}",
        oscal_uuid: "cat-uuid-#{System.unique_integer([:positive])}"
      },
      authorize?: false
    )
  end

  defp publish_version(catalog, version, opts \\ []) do
    Domain.create_catalog_version(
      %{
        catalog_id: catalog.id,
        version: version,
        source: "test",
        content_hash: opts[:content_hash] || Base.encode16(crypto_digest(version)),
        published_at: Keyword.get(opts, :published_at, @now)
      },
      authorize?: false
    )
  end

  defp crypto_digest(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))

  defp latest_at(catalog_id, at) do
    Domain.latest_catalog_version!(catalog_id, as_of: at, authorize?: false)
  end

  # --- the period IS the publication window ------------------------------------

  test "a publication lands as the half-open [published_at, ∞) period" do
    catalog = create_catalog()
    t0 = hours_after(@now, -24)

    {:ok, version} = publish_version(catalog, "1.0", published_at: t0)

    assert same_instant?(version.valid_at.lower, t0)
    assert version.valid_at.upper == nil
    assert version.valid_at.bounds == :"[)"

    # The name survives as the derived plain read over the period.
    version = Ash.load!(version, [:published_at], authorize?: false)
    assert same_instant?(version.published_at, t0)

    # ...and filters at the data layer (SQL lower()), as the column did.
    visible =
      CatalogVersion
      |> Ash.Query.filter(catalog_id == ^catalog.id and published_at >= ^t0)
      |> Ash.read!(authorize?: false)

    assert [%{id: id}] = visible
    assert id == version.id

    assert CatalogVersion
           |> Ash.Query.filter(catalog_id == ^catalog.id and published_at > ^t0)
           |> Ash.read!(authorize?: false) == []
  end

  test "an undated publication opens at the write instant" do
    catalog = create_catalog()

    {:ok, version} =
      Domain.create_catalog_version(
        %{
          catalog_id: catalog.id,
          version: "1.0",
          content_hash: Base.encode16(crypto_digest("undated"))
        },
        authorize?: false
      )

    assert DateTime.diff(DateTime.utc_now(), version.valid_at.lower) < 60
    assert version.valid_at.upper == nil
  end

  # --- §4(a): in-force-at-T across the publication boundary ----------------------

  test "as-of before the publication the version is not visible; as-of after it is" do
    catalog = create_catalog()

    # A publication dated a day OUT (relative to the real clock, not a
    # fixture clock: an open-ended period opened in the fixture past would
    # already contain today, and the plain read would rightly see it).
    tomorrow = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)

    {:ok, version} = publish_version(catalog, "2.0", published_at: tomorrow)

    # Before the boundary: the future-dated publication is invisible to
    # the pinned read and to the plain (as-of-now) read alike.
    assert latest_at(catalog.id, DateTime.utc_now()) == nil

    assert CatalogVersion
           |> Ash.Query.filter(catalog_id == ^catalog.id)
           |> Ash.read!(authorize?: false) == []

    # At the boundary instant itself (inclusive lower bound): in force.
    latest = Ash.load!(latest_at(catalog.id, tomorrow), [:published_at], authorize?: false)
    assert latest.id == version.id
    assert same_instant?(latest.published_at, tomorrow)

    # And after it.
    assert latest_at(catalog.id, hours_after(tomorrow, 1)).id == version.id
  end

  test "as-of reads straddle a backdated publication's boundary in both directions" do
    catalog = create_catalog()
    t0 = hours_after(@now, -48)

    {:ok, _version} = publish_version(catalog, "1.0", published_at: t0)

    assert latest_at(catalog.id, hours_after(t0, -1)) == nil
    assert latest_at(catalog.id, t0).version == "1.0"
    assert latest_at(catalog.id, hours_after(t0, 1)).version == "1.0"
  end

  # --- §4(f): determinism of the catalog read path at pinned instants -------------
  #
  # The compiler's gather threads its pinned `now` through the override and
  # revision reads; it never reads CatalogVersion (grep-verified: zero
  # references in compiler.ex). The catalog read path anything downstream
  # uses is `latest_for_catalog`, so determinism here is proven at that
  # read: its answer is a function of the pinned instant alone.

  test "the latest read at a pinned instant is stable across later writes and re-reads" do
    catalog = create_catalog()
    t1 = hours_after(@now, -24)
    t2 = hours_after(@now, -1)

    {:ok, v1} = publish_version(catalog, "1.0", published_at: t1)

    # Pinned at t1: exactly v1.
    assert latest_at(catalog.id, t1).id == v1.id

    # A later publication lands (pinned at t2, which is still in the past
    # relative to the fixture clock).
    {:ok, v2} = publish_version(catalog, "2.0", published_at: t2)

    # The pinned answer at t1 did not move: history is not rewritten by
    # later writes — the property a deterministic compile clock needs.
    assert latest_at(catalog.id, t1).id == v1.id

    # At t2 and at now, v2 is the latest; re-reads at the same pin agree.
    assert latest_at(catalog.id, t2).id == v2.id
    assert latest_at(catalog.id, t2).id == v2.id

    # Backdating a THIRD version does not disturb either pinned answer;
    # the earliest pin moves to v0 only inside v0's own window.
    {:ok, v0} = publish_version(catalog, "0.9", published_at: hours_after(t1, -24))

    assert latest_at(catalog.id, t1).id == v1.id
    assert latest_at(catalog.id, t2).id == v2.id
    assert latest_at(catalog.id, hours_after(t1, -1)).id == v0.id
  end

  # --- latest is containment, not insertion order ---------------------------------

  test "a backdated publication ranks by publication instant, not row insertion" do
    catalog = create_catalog()
    t_early = hours_after(@now, -48)
    t_late = hours_after(@now, -24)

    # Created in the opposite order of their publication instants: the row
    # inserted LAST carries the EARLIER publication. The old
    # insertion-order convention would have ranked it first forever.
    {:ok, late} = publish_version(catalog, "2.0", published_at: t_late)
    {:ok, early} = publish_version(catalog, "1.0", published_at: t_early)

    # As of the window where only the early publication is in force, the
    # early one is the latest — insertion order would say otherwise.
    at_between = hours_after(t_early, 1)
    assert latest_at(catalog.id, at_between).id == early.id

    # From the later publication onward, the later one is the latest.
    assert latest_at(catalog.id, @now).id == late.id
  end

  # --- identities under periods ----------------------------------------------------

  test "unique_version still rejects a duplicate version for the catalog" do
    catalog = create_catalog()

    {:ok, _first} = publish_version(catalog, "1.0")

    assert {:error, %Ash.Error.Invalid{} = error} = publish_version(catalog, "1.0")

    assert Enum.any?(error.errors, &(&1.message =~ "has already been taken"))
  end

  test "unique_hash still rejects the same content for the catalog" do
    catalog = create_catalog()
    hash = Base.encode16(crypto_digest("same-content"))

    {:ok, _first} = publish_version(catalog, "1.0", content_hash: hash)

    assert {:error, %Ash.Error.Invalid{} = _error} =
             publish_version(catalog, "2.0", content_hash: hash)
  end
end
