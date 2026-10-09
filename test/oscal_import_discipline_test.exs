# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OscalImportDisciplineTest do
  @moduledoc """
  The OSCAL import-discipline contracts (the §8.2 option-(ii) follow-up:
  the behavior change rides as its own ticket with its own contracts).

    * **Same-content re-import is a no-op** — the ruling: identical
      content on the catalog's latest version writes nothing.
    * **Different content opens a new version and withdraws the
      predecessors it supersedes** — at the import instant, period-split
      (the multi-active drift is killed at its source); as-of reads
      before the instant still see the predecessor in force.
    * **A version string that already exists with different content is
      refused** — a re-import must carry a new `metadata.version`.
    * **Historical imports land at their declared instant** —
      `published_at:` pins the version's period lower bound and the
      control revisions' creation instants.
    * **Provisioning via `set_revisions` preserves history** — the
      contract hosts must follow instead of delete-and-recreate (no
      in-repo seed/provisioning code exists; this pins the shape).
  """

  use AshCompliance.DataCase, async: true

  require Ash.Query

  alias AshCompliance.Domain
  alias AshCompliance.Oscal
  alias AshCompliance.Resources.CatalogVersion
  alias AshCompliance.Resources.ControlRevision

  @org Ecto.UUID.generate()
  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  @catalog_document %{
    "uuid" => "cat-uuid-1",
    "metadata" => %{"title" => "KYC Baseline", "version" => "1.0", "source" => "test"},
    "groups" => [
      %{
        "id" => "kyc",
        "title" => "KYC",
        "controls" => [
          %{"id" => "kyc.review", "title" => "Review", "version" => "1.0"},
          %{"id" => "kyc.valid_required", "title" => "Valid KYC", "version" => "1.0"}
        ]
      }
    ]
  }

  defp hours_after(dt, hours), do: DateTime.add(dt, hours * 3600, :second)

  defp revised_document(version, statement_override) do
    controls =
      @catalog_document
      |> get_in(["groups", Access.at(0), "controls"])
      |> Enum.map(fn control ->
        control =
          if control["id"] == "kyc.review" do
            Map.put(control, "statement", statement_override)
          else
            control
          end

        # A changed document re-publishes its controls under new versions.
        Map.put(control, "version", version)
      end)

    %{@catalog_document | "metadata" => %{@catalog_document["metadata"] | "version" => version}}
    |> put_in(["groups", Access.at(0), "controls"], controls)
  end

  defp control_by_id(catalog_id, control_id) do
    Enum.find(
      Domain.controls_for_catalog!(catalog_id, authorize?: false),
      &(&1.control_id == control_id)
    )
  end

  defp actives(control_id, opts \\ []) do
    Domain.active_control_revisions!(control_id, Keyword.merge([authorize?: false], opts))
  end

  defp count_versions(catalog_id) do
    CatalogVersion
    |> Ash.Query.filter(catalog_id == ^catalog_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  # --- same-content re-import is a no-op ---------------------------------------

  test "re-importing identical content writes nothing" do
    {:ok, catalog} = Oscal.import_catalog(@catalog_document, organization_id: @org)

    versions_before = count_versions(catalog.id)
    review = control_by_id(catalog.id, "kyc.review")
    actives_before = actives(review.id)

    {:ok, same} = Oscal.import_catalog(@catalog_document, organization_id: @org)

    assert same.id == catalog.id
    assert count_versions(catalog.id) == versions_before

    # Nothing written: the same revision rows, untouched.
    assert Enum.map(actives(review.id), &{&1.id, &1.version}) ==
             Enum.map(actives_before, &{&1.id, &1.version})

    assert length(actives(review.id)) == 1
  end

  # --- different content: new version, predecessors withdrawn at the instant -----

  test "a changed document opens a new version and withdraws the predecessor at the instant" do
    t0 = hours_after(@now, -48)
    t1 = hours_after(@now, -1)

    {:ok, catalog} =
      Oscal.import_catalog(@catalog_document, organization_id: @org, published_at: t0)

    {:ok, catalog} =
      Oscal.import_catalog(revised_document("2.0", "review tightened"),
        organization_id: @org,
        published_at: t1
      )

    assert count_versions(catalog.id) == 2

    # At now: exactly one active revision per control — the new one.
    review = control_by_id(catalog.id, "kyc.review")
    assert [%{version: "2.0"}] = actives(review.id)

    # As-of before the re-import instant: the predecessor is what was in
    # force — the withdrawal is a period split, not an erasure.
    assert [%{version: "1.0"}] = actives(review.id, as_of: hours_after(t1, -1))

    # Adjacency: the successor's period opens exactly at the import instant.
    assert DateTime.compare(hd(actives(review.id)).valid_at.lower, t1) == :eq
  end

  test "a re-import over the old multi-active drift drains it in one pass" do
    {:ok, catalog} =
      Oscal.import_catalog(@catalog_document,
        organization_id: @org,
        published_at: hours_after(@now, -48)
      )

    # Simulate the pre-discipline drift: a second active revision on one
    # control (host-created, before import-withdraws existed), pinned
    # before the re-import instant so the withdrawal can act on it.
    review = control_by_id(catalog.id, "kyc.review")

    {:ok, _drift} =
      Domain.create_control_revision(
        %{
          control_id: review.id,
          version: "drift",
          statement: "drifted active",
          status: :active
        },
        authorize?: false,
        as_of: hours_after(@now, -2)
      )

    assert length(actives(review.id)) == 2

    {:ok, _catalog} =
      Oscal.import_catalog(revised_document("2.0", "review tightened"),
        organization_id: @org,
        published_at: @now
      )

    # Every active predecessor was withdrawn; exactly one active remains.
    assert [%{version: "2.0"}] = actives(review.id)
  end

  # --- version-string collision with different content is refused -----------------

  test "a re-import repeating a version string with different content is refused" do
    {:ok, catalog} = Oscal.import_catalog(@catalog_document, organization_id: @org)

    assert {:error, message} =
             Oscal.import_catalog(revised_document("1.0", "changed under the same version"),
               organization_id: @org
             )

    assert message =~ "already exists for this catalog"
    assert message =~ "new metadata.version"

    # Nothing written: still one version, predecessor untouched.
    assert count_versions(catalog.id) == 1

    review = control_by_id(catalog.id, "kyc.review")
    assert [%{version: "1.0"}] = actives(review.id)
  end

  # --- historical imports land at their declared instant ---------------------------

  test "published_at pins the whole import's instants" do
    t0 = hours_after(@now, -72)

    {:ok, catalog} =
      Oscal.import_catalog(@catalog_document, organization_id: @org, published_at: t0)

    latest =
      Ash.load!(Domain.latest_catalog_version!(catalog.id, authorize?: false), [:published_at],
        authorize?: false
      )

    assert DateTime.compare(latest.published_at, t0) == :eq

    review = control_by_id(catalog.id, "kyc.review")
    [revision] = actives(review.id)
    assert DateTime.compare(revision.valid_at.lower, t0) == :eq

    # The declared instant is what a pinned read sees: as-of just after
    # the import, the version is the latest in force.
    assert %{id: id} =
             Domain.latest_catalog_version!(catalog.id,
               as_of: hours_after(t0, 1),
               authorize?: false
             )

    assert id == latest.id
  end

  test "profile imports accept the declared instant too" do
    t0 = hours_after(@now, -48)

    {:ok, profile} =
      Oscal.import_profile(
        %{
          "uuid" => "prof-1",
          "metadata" => %{"title" => "Tailoring", "version" => "1.0"},
          "operations" => [%{"op" => "include", "target" => "kyc.review"}]
        },
        organization_id: @org,
        published_at: t0
      )

    [revision] = Domain.profile_revisions_for_profile!(profile.id, authorize?: false)
    revision = Ash.load!(revision, [:effective_from], authorize?: false)
    assert DateTime.compare(revision.effective_from, t0) == :eq
  end

  # --- provisioning via set_revisions preserves history (the host contract) ---------

  test "provisioning through set_revisions keeps one set id and its history" do
    {:ok, catalog} = Oscal.import_catalog(@catalog_document, organization_id: @org)

    review = control_by_id(catalog.id, "kyc.review")
    [revision] = actives(review.id)

    t0 = hours_after(@now, -24)
    t1 = hours_after(@now, -1)

    {:ok, set} =
      Domain.create_tenant_policy_set(
        %{organization_id: @org, name: "provisioned", rule_set_revision_ids: []},
        authorize?: false,
        as_of: t0
      )

    # The provisioning change (never delete-and-recreate): same id, new period.
    Domain.set_revisions!(set, %{rule_set_revision_ids: [revision.id]},
      authorize?: false,
      as_of: t1
    )

    before = Domain.tenant_policy_set!(@org, as_of: hours_after(t0, 1), authorize?: false)
    after_ = Domain.tenant_policy_set!(@org, as_of: hours_after(t1, 1), authorize?: false)

    assert before.id == set.id
    assert after_.id == set.id
    assert before.rule_set_revision_ids == []
    assert after_.rule_set_revision_ids == [revision.id]
  end

  # --- the per-control ruling ------------------------------------------------------

  test "a re-import that changed one control skips the unchanged one" do
    t0 = hours_after(@now, -48)

    {:ok, catalog} =
      Oscal.import_catalog(@catalog_document, organization_id: @org, published_at: t0)

    review = control_by_id(catalog.id, "kyc.review")

    # The document changes kyc.review but leaves kyc.valid_required alone.
    {:ok, _catalog} =
      Oscal.import_catalog(revised_document("2.0", "review tightened"),
        organization_id: @org,
        published_at: @now
      )

    valid_required = control_by_id(catalog.id, "kyc.valid_required")

    # The unchanged control: same revision row, no new period, still active.
    assert Enum.map(actives(valid_required.id), &{&1.id, &1.version}) ==
             Enum.map(
               Domain.active_control_revisions!(valid_required.id,
                 as_of: hours_after(@now, 1),
                 authorize?: false
               ),
               &{&1.id, &1.version}
             )

    assert length(actives(valid_required.id)) == 1

    # The changed control: withdrawn predecessor + new active successor.
    assert [%{version: "2.0"}] = actives(review.id)
    assert [%{version: "1.0"}] = actives(review.id, as_of: hours_after(@now, -1))
  end

  test "changed content under a used control version is refused before any withdrawal" do
    {:ok, catalog} = Oscal.import_catalog(@catalog_document, organization_id: @org)

    review = control_by_id(catalog.id, "kyc.review")

    # The document bumps the catalog version but repeats kyc.review's
    # control version "1.0" with different content.
    document =
      @catalog_document
      |> put_in(["metadata", "version"], "2.0")
      |> put_in(
        ["groups", Access.at(0), "controls", Access.at(0), "statement"],
        "changed under the same control version"
      )

    assert {:error, message} = Oscal.import_catalog(document, organization_id: @org)

    assert message =~ "control \"kyc.review\" version \"1.0\" already exists"
    assert message =~ "new control version"

    # Nothing was written for the control: no withdrawal, no new revision.
    assert length(actives(review.id)) == 1
    assert [%{version: "1.0"}] = actives(review.id)
    assert count_versions(catalog.id) == 2
  end

  # --- the withdrawal rides the temporal machinery (no new write paths) -------------

  test "the withdrawal is an ordinary period-split under the identity exclusion" do
    t0 = hours_after(@now, -48)

    {:ok, catalog} =
      Oscal.import_catalog(@catalog_document, organization_id: @org, published_at: t0)

    {:ok, _catalog} =
      Oscal.import_catalog(revised_document("2.0", "review tightened"),
        organization_id: @org,
        published_at: @now
      )

    review = control_by_id(catalog.id, "kyc.review")

    # The plain read (as-of-now) returns one row per revision id: the
    # withdrawn predecessor's current period and the active successor.
    rows =
      ControlRevision
      |> Ash.Query.filter(control_id == ^review.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.version, &1.status})
      |> Enum.sort()

    assert rows == [{"1.0", :withdrawn}, {"2.0", :active}]

    # The predecessor's active history is one as-of read away.
    assert [%{version: "1.0", status: :active}] =
             actives(review.id, as_of: hours_after(@now, -1))

    # And the successor opened exactly at the import instant.
    [successor] = actives(review.id)
    assert DateTime.compare(successor.valid_at.lower, @now) == :eq
  end
end
