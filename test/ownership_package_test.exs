# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipPackageTest do
  @moduledoc """
  `AshCompliance.Ownership.Package.sections/4`: the compliance plane's part of an audit
  package for one organization and one period. Evidence comes from the hot table and the
  archive together and is re-checked against its hash; freshness is evaluated at the end
  of the period with the waivers in force then; findings are those open in the period.
  """

  use AshCompliance.DataCase, async: false

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Domain
  alias AshCompliance.Ownership.{Evidence, Freshness, Package, Retention}
  alias AshCompliance.Resources.{EvidenceArtifact, Finding}
  alias AshCompliance.TestRepo

  @now ~U[2026-11-10 12:00:00.000000Z]
  @producer "module:Producer"

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
        Keyword.get(opts, :content, "content-#{System.unique_integer([:positive])}"),
        Keyword.merge([producer: @producer, now: @now, collected_at: days_ago(days)], opts)
      )

    artifact
  end

  defp controls_file(fun \\ & &1) do
    rows = rows() |> with_row("CC6.1", &Map.put(&1, "frequency", "annual")) |> fun.()
    tmp_file("controls.json", Jason.encode!(%{"frameworks" => ["soc2"], "criteria" => rows}))
  end

  defp sections!(org, from, to, opts \\ []) do
    {:ok, sections} =
      Package.sections(
        org,
        from,
        to,
        Keyword.merge([controls_file: controls_file(), generated_at: @now], opts)
      )

    sections
  end

  defp criterion(sections, id), do: Enum.find(sections.evidence["criteria"], &(&1["id"] == id))

  describe "evidence" do
    test "comes from the hot table and the archive, each artifact re-checked against its hash",
         %{org: org} do
      before = record!(org, "CC6.1", 400)
      archived1 = record!(org, "CC6.1", 200)
      archived2 = record!(org, "CC6.1", 150)
      hot = record!(org, "CC6.1", 10)

      {:ok, {:archived, %{row_count: 3}}} = Retention.archive(now: @now)

      TestRepo.query!("UPDATE ash_compliance_evidence_artifacts SET content = $2 WHERE id = $1", [
        Ecto.UUID.dump!(hot.id),
        "altered"
      ])

      sections = sections!(org, days_ago(250), @now)
      artifacts = criterion(sections, "CC6.1")["artifacts"]

      assert Enum.map(artifacts, & &1["id"]) ==
               Enum.map([before, archived1, archived2, hot], & &1.id)

      assert Enum.map(artifacts, & &1["location"]) == ~w(archive archive archive hot)
      assert Enum.map(artifacts, & &1["in_period"]) == [false, true, true, true]

      assert Enum.map(artifacts, & &1["integrity"]) ==
               ~w(verified verified verified hash_mismatch)

      # The newest artifact no longer verifies, so freshness rests on the newest one that
      # does, which is in the archive.
      freshness = criterion(sections, "CC6.1")["freshness"]
      assert freshness["state"] == "evidenced"
      assert freshness["latest_at"] == DateTime.to_iso8601(archived2.collected_at)
    end

    test "carries text content inline and anything else by its hash", %{org: org} do
      record!(org, "CC6.1", 1, content: ~s({"ok":true}), media_type: "application/json")
      record!(org, "CC6.1", 1, content: <<0, 1, 2>>, media_type: "application/octet-stream")

      artifacts = criterion(sections!(org, days_ago(30), @now), "CC6.1")["artifacts"]
      json = Enum.find(artifacts, &(&1["media_type"] == "application/json"))
      binary = Enum.find(artifacts, &(&1["media_type"] == "application/octet-stream"))

      assert json["content"] == ~s({"ok":true})
      assert binary["content"] == nil
      assert binary["content_omitted"] =~ "not text"
    end
  end

  describe "freshness at the end of the period" do
    test "counts only what was collected by then, with the waivers in force then",
         %{org: org} do
      period_end = days_ago(100)

      # Collected after the period: not evidence for it.
      record!(org, "CC6.2", 50)

      Domain.create_policy_override!(
        %{
          organization_id: org,
          kind: :waive,
          rule_id: Freshness.rule_id("CC6.3"),
          reason: "documented exception",
          approver: "security-officer",
          requested_by: "ops-engineer",
          approved_at: days_ago(131),
          starts_at: days_ago(130),
          expires_at: days_ago(70),
          compensating_controls: ["manual-review"]
        },
        authorize?: false
      )

      sections = sections!(org, days_ago(200), period_end)
      assert sections.period.as_of == period_end

      cc62 = criterion(sections, "CC6.2")
      assert cc62["freshness"]["state"] == "unknown"
      assert cc62["freshness"]["reason"] == "no_evidence"
      assert cc62["artifacts"] == []

      cc63 = criterion(sections, "CC6.3")["freshness"]
      assert cc63["state"] == "unknown"
      assert cc63["silenced_by"]["approver"] == "security-officer"

      # The same waiver is not in force at a later period's end.
      later = sections!(org, days_ago(60), days_ago(10))
      assert criterion(later, "CC6.3")["freshness"]["silenced_by"] == nil
      assert criterion(later, "CC6.2")["freshness"]["state"] == "unknown"
    end

    test "is evaluated at the export time when the period has not ended", %{org: org} do
      record!(org, "CC6.2", 0)
      generated_at = DateTime.add(@now, 60, :second)
      sections = sections!(org, days_ago(1), days_ago(-30), generated_at: generated_at)

      assert sections.period.as_of == generated_at
      assert criterion(sections, "CC6.2")["freshness"]["state"] == "evidenced"
    end
  end

  describe "controls and findings" do
    test "lists the criteria in scope with the control file's row for each", %{org: org} do
      sections = sections!(org, days_ago(30), @now, categories: [:security, :availability])
      ids = Enum.map(sections.controls["criteria"], & &1["id"])

      assert "CC6.1" in ids and "A1.1" in ids
      assert sections.controls["categories"] == ["security", "availability"]
      assert sections.controls["control_file"]["loaded"]
      assert sections.controls["control_file"]["sha256"] =~ ~r/\A[0-9a-f]{64}\z/

      cc61 = Enum.find(sections.controls["criteria"], &(&1["id"] == "CC6.1"))
      assert cc61["row"]["frequency"] == "annual"
    end

    test "a missing control file is reported, and every criterion is unknown", %{org: org} do
      sections = sections!(org, days_ago(30), @now, controls_file: "/nonexistent/controls.json")

      refute sections.controls["control_file"]["loaded"]

      assert Enum.all?(
               sections.evidence["criteria"],
               &(&1["freshness"]["state"] == "unknown")
             )
    end

    test "lists the findings open at any time in the period", %{org: org} do
      finding!(org, "CC7.1", first_seen: days_ago(60), resolved: days_ago(40))
      finding!(org, "CC7.2", first_seen: days_ago(20), resolved: nil)
      finding!(org, "CC7.3", first_seen: days_ago(60), resolved: days_ago(5))
      finding!(org, "CC7.4", first_seen: days_ago(1), resolved: nil)

      sections = sections!(org, days_ago(30), days_ago(2))

      assert Enum.map(sections.findings["findings"], & &1["control_id"]) == ["CC7.2", "CC7.3"]
    end

    test "carries the host's observations and findings through unchanged", %{org: org} do
      observation = %{
        id: "host:1",
        title: "t",
        description: "d",
        methods: [:test],
        collected: @now
      }

      finding = %{id: "host:2", title: "t", description: "d", control_id: "CC7.2", reason: :fail}

      sections =
        sections!(org, days_ago(30), @now,
          extra_observations: [observation],
          extra_findings: [finding]
        )

      assert sections.extra_observations == [observation]
      assert sections.extra_findings == [finding]
    end

    test "refuses a period that does not run forwards", %{org: org} do
      assert {:error, :invalid_period} =
               Package.sections(org, @now, @now, controls_file: controls_file())
    end
  end

  defp finding!(org, control, first_seen: first_seen, resolved: resolved) do
    grain = %{
      organization_id: org,
      control_id: control,
      subject_type: "record",
      subject_id: "r-1"
    }

    {:ok, row} = Domain.upsert_finding_grain(grain, authorize?: false)

    {:ok, _} =
      Domain.apply_finding_ops(
        row,
        [
          {:set, :status, :noncompliant},
          {:set, :first_seen_at, first_seen},
          {:set, :last_seen_at, first_seen},
          {:set, :resolved_at, resolved}
        ],
        authorize?: false
      )
  end
end
