# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.EvidenceArchiveTest do
  @moduledoc """
  The evidence archive: the resource macro, the verified move from the hot table, the
  newest artifact of each organization, control and collector staying hot, the purge and
  its floors, and the reads (`Evidence.for_control/3`, the freshness sweep) that take
  the hot table and the archive together. Against real Postgres, with the test app's
  archive (`AshCompliance.Test.ArchivedEvidence`).
  """

  use AshCompliance.DataCase, async: false

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Ownership.{Evidence, Retention, Sweep}
  alias AshCompliance.Resources.{EvidenceArtifact, Finding}
  alias AshCompliance.Test.{ArchivedEvidence, ArchiveRun}
  alias AshCompliance.TestRepo

  @now ~U[2026-11-10 12:00:00.000000Z]
  @producer "module:Producer"
  @hot "ash_compliance_evidence_artifacts"
  @archive "evidence_artifact_archive"

  setup do
    TestRepo.delete_all(Finding)
    TestRepo.delete_all(EvidenceArtifact)
    %{org: Ecto.UUID.generate()}
  end

  defp days_ago(days), do: DateTime.add(@now, -days * 86_400, :second)

  defp record!(org, control, days, opts \\ []) do
    {:ok, artifact} =
      Evidence.record(
        org,
        control,
        "content-#{System.unique_integer([:positive])}",
        Keyword.merge([producer: @producer, now: @now, collected_at: days_ago(days)], opts)
      )

    artifact
  end

  # Sets when `artifact` was recorded (`inserted_at`, which no caller can set) to `days`
  # before `@now`, in the hot table, so it can be archived and purged as an artifact
  # recorded that long ago.
  defp recorded!(artifact, days) do
    TestRepo.query!("UPDATE #{@hot} SET inserted_at = $2 WHERE id = $1", [
      Ecto.UUID.dump!(artifact.id),
      days_ago(days)
    ])

    artifact
  end

  defp hot_ids, do: ids(@hot)
  defp archived_ids, do: ids(@archive)

  # sobelow_skip ["SQL.Query"]
  defp ids(table) do
    %{rows: rows} = TestRepo.query!("SELECT id::text FROM #{table}")
    rows |> List.flatten() |> MapSet.new()
  end

  defp tamper!(artifact) do
    TestRepo.query!("UPDATE #{@hot} SET content = $2 WHERE id = $1", [
      Ecto.UUID.dump!(artifact.id),
      "altered"
    ])
  end

  defp annual_controls_file do
    rows = with_row(rows(), "CC6.1", &Map.put(&1, "frequency", "annual"))
    tmp_file("controls.json", Jason.encode!(%{"criteria" => rows}))
  end

  # Raw SQL the database is expected to refuse, in its own savepoint so the test's
  # transaction carries on.
  defp refused(sql, params) do
    assert_raise Postgrex.Error, fn ->
      TestRepo.transaction(fn -> TestRepo.query!(sql, params) end)
    end
  end

  describe "reading evidence across the move" do
    test "moving evidence to the archive never changes what the sweep finds", %{org: org} do
      file = annual_controls_file()
      older = record!(org, "CC6.1", 200)
      newest = record!(org, "CC6.1", 100)
      # The newest artifact's bytes no longer match its hash, so the criterion rests on
      # the older one, which the move takes to the archive.
      tamper!(newest)

      {:ok, before} = Sweep.run(org, controls_file: file, now: @now)
      before_cc61 = Enum.find(before, &(&1.criterion == "CC6.1"))
      assert before_cc61.state == :evidenced
      assert DateTime.compare(before_cc61.latest_at, older.collected_at) == :eq

      assert {:ok, {:archived, %{row_count: 1}}} = Retention.archive(now: @now)
      assert archived_ids() == MapSet.new([older.id])
      assert MapSet.member?(hot_ids(), newest.id)

      {:ok, after_move} = Sweep.run(org, controls_file: file, now: @now)
      assert after_move == before
    end

    test "for_control reads the hot table and the archive, each artifact once, oldest first",
         %{org: org} do
      a = record!(org, "CC6.1", 300)
      b = record!(org, "CC6.1", 200)
      c = record!(org, "CC6.1", 1)
      _other_control = record!(org, "CC6.2", 300)

      {:ok, {:archived, _}} = Retention.archive(now: @now)

      {:ok, read} = Evidence.for_control(org, "CC6.1")
      assert Enum.map(read, & &1.id) == [a.id, b.id, c.id]
      assert Enum.map(read, &Evidence.location/1) == [:archive, :archive, :hot]
      assert Enum.all?(read, &(Evidence.verify(&1) == :ok))

      # Without an archive only the hot table is read.
      {:ok, hot_only} = Evidence.for_control(org, "CC6.1", archive: nil)
      assert Enum.map(hot_only, & &1.id) == [c.id]
    end
  end

  describe "archive/1" do
    test "keeps the newest artifact of each organization, control and collector hot",
         %{org: org} do
      other_org = Ecto.UUID.generate()

      a1 = record!(org, "CC6.1", 300)
      a2 = record!(org, "CC6.1", 200)
      only_from_b = record!(org, "CC6.1", 150, producer: "module:Other")
      only_for_cc62 = record!(org, "CC6.2", 120)
      d1 = record!(other_org, "CC6.1", 100)
      d2 = record!(other_org, "CC6.1", 95)
      recent1 = record!(org, "CC7.1", 10)
      recent2 = record!(org, "CC7.1", 5)

      assert {:ok, {:archived, %{row_count: 2}}} = Retention.archive(now: @now)

      assert archived_ids() == MapSet.new([a1.id, d1.id])

      assert hot_ids() ==
               MapSet.new(
                 Enum.map([a2, only_from_b, only_for_cc62, d2, recent1, recent2], & &1.id)
               )

      assert {:ok, :nothing} = Retention.archive(now: @now)
    end

    test "the copy is the hot row, and the move is recorded in the run ledger", %{org: org} do
      first = record!(org, "CC6.1", 300, media_type: "application/json", subject_id: "s-1")
      second = record!(org, "CC6.1", 250)
      _newest = record!(org, "CC6.1", 1)

      assert {:ok, {:archived, %ArchiveRun{} = run}} =
               Retention.archive(now: @now, archive_run: ArchiveRun)

      digest =
        [first, second]
        |> Enum.sort_by(& &1.id)
        |> Enum.map_join("|", & &1.hash)
        |> Evidence.sha256()

      assert %{
               store: :evidence_artifacts,
               kind: :archive,
               status: :verified,
               row_count: 2,
               digest: ^digest
             } = run

      assert DateTime.compare(run.cutoff, days_ago(90)) == :eq

      for original <- [first, second] do
        copy = Ash.get!(ArchivedEvidence, original.id, authorize?: false)

        for column <- AshCompliance.Resources.columns() -- [:method] do
          assert Map.fetch!(copy, column) == Map.fetch!(original, column), "#{column} differs"
        end

        assert copy.method == to_string(original.method)
        assert DateTime.compare(copy.archived_at, @now) == :eq
        assert Evidence.verify(copy) == :ok
      end
    end

    test "an archived copy that differs from the hot row stops the move", %{org: org} do
      old = record!(org, "CC6.1", 300)
      _newest = record!(org, "CC6.1", 1)

      TestRepo.query!(
        """
        INSERT INTO #{@archive} (id, organization_id, control_id, hash, media_type, collector,
          method, collected_at, inserted_at, archived_at)
        SELECT id, organization_id, control_id, $2, media_type, collector, method,
          collected_at, inserted_at, $3
        FROM #{@hot} WHERE id = $1
        """,
        [Ecto.UUID.dump!(old.id), String.duplicate("0", 64), @now]
      )

      assert {:ok, {:failed, %ArchiveRun{status: :failed, kind: :archive, reason: reason}}} =
               Retention.archive(now: @now, archive_run: ArchiveRun)

      assert reason =~ "differ from the hot row"
      assert MapSet.member?(hot_ids(), old.id)

      assert Ash.get!(ArchivedEvidence, old.id, authorize?: false).hash ==
               String.duplicate("0", 64)
    end

    test "refuses a hot window under ninety days and works without a run ledger" do
      assert {:error, {:below_floor, :hot_days, 90}} = Retention.archive(hot_days: 30)
      assert {:error, :no_evidence_archive} = Retention.archive(archive: nil)
      assert {:ok, :nothing} = Retention.archive(now: @now, hot_days: 365)
    end
  end

  describe "purge/1" do
    test "never runs unless an age is given, and refuses one under four hundred days" do
      assert {:ok, :disabled} = Retention.purge(now: @now)

      assert {:error, {:below_floor, :purge_after_days, 400}} =
               Retention.purge(now: @now, purge_after_days: 399)
    end

    test "a back-dated collected_at is not purged before 400 days from insertion",
         %{org: org} do
      # Collected, its collector says, 500 days ago; recorded today.
      backdated = record!(org, "CC6.1", 500)
      recorded_long_ago = record!(org, "CC6.1", 450) |> recorded!(450)
      _newest = record!(org, "CC6.1", 1)

      {:ok, {:archived, %{row_count: 2}}} = Retention.archive(now: @now)

      assert {:ok, {:purged, %ArchiveRun{row_count: 1}}} =
               Retention.purge(now: @now, purge_after_days: 400, archive_run: ArchiveRun)

      assert archived_ids() == MapSet.new([backdated.id])
      refute MapSet.member?(archived_ids(), recorded_long_ago.id)

      # A second purge finds nothing, and the database refuses the row whoever asks.
      assert {:ok, :nothing} = Retention.purge(now: @now, purge_after_days: 400)
      refused("DELETE FROM #{@archive} WHERE id = $1", [Ecto.UUID.dump!(backdated.id)])
      assert archived_ids() == MapSet.new([backdated.id])
    end

    test "deletes archived artifacts past the purge age, and records the purge", %{org: org} do
      oldest = record!(org, "CC6.1", 600) |> recorded!(600)
      kept = record!(org, "CC6.1", 500) |> recorded!(500)
      _newest = record!(org, "CC6.1", 450)

      {:ok, {:archived, %{row_count: 2}}} = Retention.archive(now: @now)

      assert {:ok, {:purged, %ArchiveRun{kind: :purge, status: :verified, row_count: 1}}} =
               Retention.purge(now: @now, purge_after_days: 550, archive_run: ArchiveRun)

      assert archived_ids() == MapSet.new([kept.id])
      refute MapSet.member?(hot_ids(), oldest.id)
    end

    test "the archive's trigger refuses an edit, and a delete younger than 400 days",
         %{org: org} do
      young = record!(org, "CC6.1", 120)
      _newest = record!(org, "CC6.1", 1)
      {:ok, {:archived, _}} = Retention.archive(now: @now)
      id = Ecto.UUID.dump!(young.id)

      refused("UPDATE #{@archive} SET hash = 'x' WHERE id = $1", [id])
      refused("DELETE FROM #{@archive} WHERE id = $1", [id])

      # A purge whose clock says the row is old enough is still refused by the database.
      far_future = DateTime.add(DateTime.utc_now(), 1_000 * 86_400, :second)

      assert {:ok, {:failed, %{status: :failed, reason: reason}}} =
               Retention.purge(now: far_future, purge_after_days: 400)

      assert reason =~ "keeps every artifact for 400 days"
      assert archived_ids() == MapSet.new([young.id])
    end
  end

  describe "the macro" do
    test "the archive copies every hot column, plus archived_at" do
      hot = EvidenceArtifact |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
      archive = ArchivedEvidence |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      assert Enum.sort(AshCompliance.Resources.columns()) == Enum.sort(hot)
      assert Enum.sort(archive) == Enum.sort([:archived_at | hot])
      assert AshCompliance.Resources.evidence_archive?(ArchivedEvidence)
      refute AshCompliance.Resources.evidence_archive?(EvidenceArtifact)
    end

    test "has no write action, and keeps the table and statement names it is given" do
      types = ArchivedEvidence |> Ash.Resource.Info.actions() |> Enum.map(& &1.type)
      assert Enum.uniq(types) == [:read]

      assert AshPostgres.DataLayer.Info.table(ArchivedEvidence) == @archive

      statements = AshPostgres.DataLayer.Info.custom_statements(ArchivedEvidence)

      assert Enum.map(statements, & &1.name) == [
               :evidence_artifact_archive_guard_function,
               :evidence_artifact_archive_guard_trigger
             ]

      # The table and trigger, then the guard as it now reads.
      migration =
        [
          "20261113120000_evidence_artifact_archive",
          "20261114120000_evidence_archive_purge_clock"
        ]
        |> Enum.map_join(" ", &File.read!("priv/test_repo/migrations/#{&1}.exs"))
        |> squash()

      for statement <- statements do
        assert String.contains?(migration, squash(statement.up)),
               "the test migration does not carry #{statement.name}"
      end
    end

    test "refuses a missing table and a table name that is not a plain identifier" do
      assert_raise ArgumentError, ~r/requires :table/, fn ->
        compile_archive("[repo: AshCompliance.TestRepo]")
      end

      assert_raise ArgumentError, ~r/not plain SQL identifiers/, fn ->
        compile_archive(~s([table: "evidence; drop", repo: AshCompliance.TestRepo]))
      end
    end
  end

  defp squash(text), do: text |> String.split() |> Enum.join(" ")

  defp compile_archive(opts) do
    Code.compile_string("""
    defmodule AshCompliance.Test.BadArchive#{System.unique_integer([:positive])} do
      use Ash.Resource, domain: AshCompliance.Test.Domain, data_layer: AshPostgres.DataLayer
      use AshCompliance.Resources, {:evidence_archive, #{opts}}
    end
    """)
  end
end
