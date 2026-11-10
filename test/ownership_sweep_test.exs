# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipSweepTest do
  @moduledoc """
  The evidence writer, the sweep that raises findings, and the Oban worker,
  against real Postgres.
  """

  use AshCompliance.DataCase, async: false

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Domain
  alias AshCompliance.Ownership.{Evidence, Freshness, Sweep}
  alias AshCompliance.Resources.{EvidenceArtifact, Finding}
  alias AshCompliance.TestRepo
  alias AshCompliance.Workers.EvidenceFreshness

  @now ~U[2026-11-10 12:00:00.000000Z]
  @producer "module:Producer"

  setup do
    TestRepo.delete_all(Finding)
    TestRepo.delete_all(EvidenceArtifact)
    %{org: Ecto.UUID.generate()}
  end

  defp hours_ago(hours), do: DateTime.add(@now, -hours * 3600, :second)

  defp controls_file(rows \\ rows()) do
    tmp_file("controls.json", Jason.encode!(%{"criteria" => rows}))
  end

  defp record!(org, control, opts \\ []) do
    {:ok, artifact} =
      Evidence.record(
        org,
        control,
        "content-#{System.unique_integer()}",
        Keyword.merge([producer: @producer, now: @now, collected_at: hours_ago(1)], opts)
      )

    artifact
  end

  defp freshness_finding(org, control) do
    org
    |> then(&Domain.findings_for_organization!(&1, authorize?: false))
    |> Enum.find(&(&1.control_id == control and &1.subject_type == "evidence_freshness"))
  end

  defp sweep(org, file, opts \\ []) do
    Sweep.run(org, Keyword.merge([controls_file: file, now: @now], opts))
  end

  describe "the evidence writer" do
    test "writes a dated, SHA-256, producer-named artifact", %{org: org} do
      artifact = record!(org, "CC6.1", media_type: "application/json")

      assert artifact.collector == @producer
      assert artifact.hash =~ ~r/\A[0-9a-f]{64}\z/
      assert artifact.media_type == "application/json"
      assert DateTime.compare(artifact.collected_at, hours_ago(1)) == :eq
      assert [%{"actor" => @producer, "action" => "collected"}] = artifact.chain_of_custody
    end

    test "the hash is the SHA-256 of the content", %{org: org} do
      {:ok, artifact} = Evidence.record(org, "CC6.1", "abc", producer: @producer, now: @now)
      assert artifact.hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end

    test "is append-only: the resource offers no update or destroy", %{org: org} do
      record!(org, "CC6.1")

      types =
        EvidenceArtifact |> Ash.Resource.Info.actions() |> Enum.map(& &1.type) |> Enum.uniq()

      assert Enum.sort(types) == [:create, :read]
    end

    test "refuses empty content, a blank producer, a bad organization and a future collection time",
         %{org: org} do
      base = [producer: @producer, now: @now]

      assert {:error, :empty_content} = Evidence.record(org, "CC6.1", "", base)

      assert {:error, :no_producer} =
               Evidence.record(org, "CC6.1", "x", Keyword.put(base, :producer, "  "))

      assert {:error, :no_producer} =
               Evidence.record(org, "CC6.1", "x", Keyword.delete(base, :producer))

      assert {:error, :invalid_organization} = Evidence.record("nope", "CC6.1", "x", base)

      future = DateTime.add(@now, 3600, :second)

      assert {:error, :future_dated} =
               Evidence.record(org, "CC6.1", "x", [collected_at: future] ++ base)

      assert {:error, :malformed_timestamp} =
               Evidence.record(org, "CC6.1", "x", [collected_at: "today"] ++ base)

      assert Domain.evidence_for_control!(org, "CC6.1", authorize?: false) == []
    end

    test "a producer that errors, raises, throws or returns nothing leaves no artifact", %{
      org: org
    } do
      opts = [producer: @producer, now: @now]

      producers = [
        fn -> {:error, :timeout} end,
        fn -> raise "boom" end,
        fn -> throw(:up) end,
        fn -> exit(:down) end,
        fn -> {:ok, ""} end,
        fn -> :ok end,
        {__MODULE__, :no_such_function, []}
      ]

      for producer <- producers do
        assert {:error, {:producer_failed, _}} = Evidence.collect(org, "CC6.1", producer, opts)
      end

      assert Domain.evidence_for_control!(org, "CC6.1", authorize?: false) == []

      assert {:ok, _} = Evidence.collect(org, "CC6.1", fn -> {:ok, "data"} end, opts)
    end

    test "a failed producer leaves the control unknown", %{org: org} do
      assert {:error, {:producer_failed, _}} =
               Evidence.collect(org, "CC6.1", fn -> {:error, :down} end,
                 producer: @producer,
                 now: @now
               )

      {:ok, results} = sweep(org, controls_file())

      assert %{state: :unknown, reason: :no_evidence} =
               Enum.find(results, &(&1.criterion == "CC6.1"))
    end
  end

  describe "the sweep" do
    test "stale evidence becomes unknown and raises a finding", %{org: org} do
      record!(org, "CC6.1", collected_at: hours_ago(24 * 10))
      {:ok, results} = sweep(org, controls_file())

      assert %{state: :unknown, reason: :stale} = Enum.find(results, &(&1.criterion == "CC6.1"))
      finding = freshness_finding(org, "CC6.1")
      assert finding.status == :unknown
      assert finding.explanation =~ "stale"
      assert finding.resolved_at == nil
    end

    test "no criterion is evidenced or compliant without evidence, and each raises a finding", %{
      org: org
    } do
      {:ok, results} = sweep(org, controls_file())

      assert length(results) == 33
      assert Enum.all?(results, &(&1.state == :unknown))
      assert length(Domain.findings_for_organization!(org, authorize?: false)) == 33

      assert Domain.findings_for_organization!(org, authorize?: false)
             |> Enum.all?(&(&1.status == :unknown))
    end

    test "a missing control file raises unknown for every criterion", %{org: org} do
      {:ok, results} = sweep(org, "/nonexistent/controls.json")
      assert Enum.all?(results, &(&1.reason == :control_file_missing))
      assert freshness_finding(org, "CC6.1").status == :unknown
    end

    test "a malformed control file raises unknown for every criterion", %{org: org} do
      {:ok, results} = sweep(org, tmp_file("controls.json", "{ nope"))
      assert Enum.all?(results, &(&1.reason == :control_file_malformed))
    end

    test "fresh evidence resolves the finding but never says compliant", %{org: org} do
      {:ok, _} = sweep(org, controls_file())
      assert freshness_finding(org, "CC6.1").resolved_at == nil

      record!(org, "CC6.1")
      {:ok, results} = sweep(org, controls_file())

      assert %{state: :evidenced} = Enum.find(results, &(&1.criterion == "CC6.1"))
      finding = freshness_finding(org, "CC6.1")
      assert finding.resolved_at
      assert finding.status == :unknown
      refute finding.status == :compliant
    end

    test "evidence that goes stale re-opens the finding", %{org: org} do
      record!(org, "CC6.1")
      {:ok, _} = sweep(org, controls_file())
      assert freshness_finding(org, "CC6.1") == nil

      later = DateTime.add(@now, 24 * 3600 * 5, :second)
      {:ok, _} = sweep(org, controls_file(), now: later)
      finding = freshness_finding(org, "CC6.1")
      assert finding.status == :unknown
      assert finding.resolved_at == nil
    end

    test "a sweep for one organization never reads another's evidence", %{org: org} do
      other = Ecto.UUID.generate()
      record!(other, "CC6.1")

      {:ok, results} = sweep(org, controls_file())

      assert %{state: :unknown, reason: :no_evidence} =
               Enum.find(results, &(&1.criterion == "CC6.1"))
    end
  end

  describe "overrides" do
    defp waive!(org, criterion, overrides \\ %{}) do
      Domain.create_policy_override!(
        Map.merge(
          %{
            organization_id: org,
            kind: :waive,
            rule_id: Freshness.rule_id(criterion),
            reason: "documented exception",
            approver: "security-officer",
            requested_by: "ops-engineer",
            approved_at: hours_ago(2),
            starts_at: hours_ago(1),
            expires_at: DateTime.add(@now, 3600, :second),
            compensating_controls: ["manual-review"]
          },
          overrides
        ),
        authorize?: false
      )
    end

    test "a waiver with approver and expiry silences the finding, and the criterion stays unknown",
         %{org: org} do
      waive!(org, "CC6.1")
      {:ok, results} = sweep(org, controls_file())

      result = Enum.find(results, &(&1.criterion == "CC6.1"))
      assert result.state == :unknown
      assert %{approver: "security-officer"} = result.silenced_by
      assert freshness_finding(org, "CC6.1") == nil
      assert freshness_finding(org, "CC6.2")
    end

    test "it stops silencing at expiry", %{org: org} do
      waive!(org, "CC6.1")
      {:ok, _} = sweep(org, controls_file())
      assert freshness_finding(org, "CC6.1") == nil

      after_expiry = DateTime.add(@now, 2 * 3600, :second)
      {:ok, results} = sweep(org, controls_file(), now: after_expiry)

      assert Enum.find(results, &(&1.criterion == "CC6.1")).silenced_by == nil
      assert freshness_finding(org, "CC6.1").status == :unknown
    end

    test "a waiver with no approver cannot be created", %{org: org} do
      for approver <- ["", nil] do
        assert {:error, _} =
                 Domain.create_policy_override(
                   %{
                     organization_id: org,
                     kind: :waive,
                     rule_id: Freshness.rule_id("CC6.1"),
                     reason: "x",
                     approver: approver,
                     requested_by: "ops-engineer",
                     approved_at: hours_ago(2),
                     starts_at: hours_ago(1),
                     expires_at: DateTime.add(@now, 3600, :second),
                     compensating_controls: ["m"]
                   },
                   authorize?: false
                 )
      end

      {:ok, results} = sweep(org, controls_file())
      assert Enum.find(results, &(&1.criterion == "CC6.1")).silenced_by == nil
    end

    test "a waiver with no expiry cannot be created", %{org: org} do
      assert {:error, _} =
               Domain.create_policy_override(
                 %{
                   organization_id: org,
                   kind: :waive,
                   rule_id: Freshness.rule_id("CC6.1"),
                   reason: "x",
                   approver: "someone",
                   requested_by: "ops-engineer",
                   approved_at: hours_ago(2),
                   starts_at: hours_ago(1),
                   compensating_controls: ["m"]
                 },
                 authorize?: false
               )
    end

    test "a waiver in another organization does not silence", %{org: org} do
      waive!(Ecto.UUID.generate(), "CC6.1")
      {:ok, results} = sweep(org, controls_file())
      assert Enum.find(results, &(&1.criterion == "CC6.1")).silenced_by == nil
    end
  end

  describe "the worker" do
    defp job_args(org, file, extra \\ %{}) do
      Map.merge(%{"organization_id" => org, "controls_file" => file}, extra)
    end

    test "succeeds and raises findings even when every criterion is unknown", %{org: org} do
      assert :ok = EvidenceFreshness.perform(%Oban.Job{args: job_args(org, controls_file())})
      assert freshness_finding(org, "CC6.1").status == :unknown
    end

    test "succeeds when the control file is missing, and raises unknown", %{org: org} do
      assert :ok =
               EvidenceFreshness.perform(%Oban.Job{
                 args: job_args(org, "/nonexistent/controls.json")
               })

      assert freshness_finding(org, "CC6.1").status == :unknown
    end

    test "categories widen the sweep", %{org: org} do
      args = job_args(org, controls_file(), %{"categories" => ["security", "availability"]})
      assert :ok = EvidenceFreshness.perform(%Oban.Job{args: args})
      assert freshness_finding(org, "A1.1").status == :unknown
    end

    test "bad arguments cancel instead of silently doing nothing", %{org: org} do
      assert {:cancel, _} = EvidenceFreshness.perform(%Oban.Job{args: %{}})

      assert {:cancel, _} =
               EvidenceFreshness.perform(%Oban.Job{
                 args: %{"organization_id" => "x", "controls_file" => "f"}
               })

      assert {:cancel, _} =
               EvidenceFreshness.perform(%Oban.Job{args: %{"organization_id" => org}})

      assert {:cancel, _} =
               EvidenceFreshness.perform(%Oban.Job{
                 args: job_args(org, "f", %{"categories" => ["nonsense"]})
               })

      assert {:cancel, _} =
               EvidenceFreshness.perform(%Oban.Job{
                 args: job_args(org, "f", %{"categories" => []})
               })
    end

    test "is enqueueable through Oban", %{org: org} do
      {:ok, job} = Oban.insert(EvidenceFreshness.new(job_args(org, "docs/controls.json")))
      assert job.queue == "compliance"
    end
  end
end
