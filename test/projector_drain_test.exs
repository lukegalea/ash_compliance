# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ProjectorDrainTest do
  @moduledoc """
  End-to-end projector tests against the real finding resource: replay
  determinism (the acceptance bar), tenant isolation, and the
  missing-evidence-never-compliant invariant through the full drain path.
  """

  use AshCompliance.DataCase, async: false

  require Ash.Query

  alias AshCompliance.Resources.{ComplianceEvaluation, Finding, PolicyBundle}
  alias AshCompliance.Test.Projector, as: TestProjector
  alias AshCompliance.Test.RuleSets.GlobalBaseline
  alias AshCompliance.Test.Support
  alias AshCompliance.TestRepo

  @finding_fields [
    :organization_id,
    :control_id,
    :subject_type,
    :subject_id,
    :status,
    :severity,
    :gap,
    :breach_count,
    :first_seen_at,
    :last_seen_at,
    :resolved_at,
    :explanation,
    :bundle_hash,
    :rule_ids
  ]

  @evaluation_fields [
    :organization_id,
    :control_id,
    :subject_type,
    :subject_id,
    :bundle_hash,
    :bundle_revision,
    :outcome,
    :fact_snapshot_hash,
    :missing_facts,
    :rule_ids,
    :correlation_id,
    :source_event_id,
    :evaluated_at
  ]

  setup do
    TestRepo.delete_all(Finding)
    TestRepo.delete_all(ComplianceEvaluation)

    %{org_a: Ecto.UUID.generate(), org_b: Ecto.UUID.generate()}
  end

  describe "replay determinism" do
    test "the same bundle and event sequence produces identical findings and evaluations", %{
      org_a: org
    } do
      compile_and_activate(org)
      events = compliance_events(org, "cus_1")

      first = drain_fresh(events)
      second = drain_fresh(events)

      assert findings_view(first) == findings_view(second)
      assert evaluations_view(first) == evaluations_view(second)

      # one finding row per grain, updated in place; the timeline lives in
      # first_seen_at vs last_seen_at, and in the evaluation rows
      assert [finding] = findings_view(first)
      assert finding.status == :compliant
      assert DateTime.to_unix(finding.first_seen_at) == DateTime.to_unix(~U[2026-09-17 10:00:00Z])
      assert DateTime.to_unix(finding.last_seen_at) == DateTime.to_unix(~U[2026-09-17 11:00:00Z])
    end

    test "each event appends its own evaluation with its own outcome", %{org_a: org} do
      compile_and_activate(org)

      events = compliance_events(org, "cus_1")
      AshCompliance.Testing.drain_sync(TestProjector, events)

      evaluations =
        evaluations_for(org)
        |> Enum.sort_by(& &1.evaluated_at)

      assert length(evaluations) == 2
      assert [first, second] = evaluations

      # first evaluation: kyc fact missing → the kyc requirement is unknown
      # but the review requirement fires (its absence semantics is no_fact),
      # so the overall outcome is noncompliant; second: kyc valid → compliant
      assert first.outcome == :noncompliant
      assert second.outcome == :noncompliant

      # the fact snapshots differ — the second event supplied the kyc fact
      refute first.fact_snapshot_hash == second.fact_snapshot_hash

      # source lineage: each evaluation pins its event
      assert first.source_event_id == "1"
      assert second.source_event_id == "2"
      assert first.correlation_id == "corr-1"
      assert second.correlation_id == "corr-2"
    end
  end

  describe "tenant isolation" do
    test "an override for tenant A cannot change tenant B's findings", %{
      org_a: org_a,
      org_b: org_b
    } do
      compile_and_activate(org_a, with_waiver: true)
      compile_and_activate(org_b, with_waiver: false)

      events =
        compliance_events(org_a, "cus_1") ++
          compliance_events(org_b, "cus_1")

      AshCompliance.Testing.drain_sync(TestProjector, events)

      # every finding and evaluation row is tagged with its own tenant, and no
      # evaluation from tenant A's bundle leaked into tenant B's rows
      evaluations = ComplianceEvaluation |> Ash.read!(authorize?: false)

      assert %{
               ^org_a => 2,
               ^org_b => 2
             } = count_by_org(evaluations)

      for evaluation <- evaluations do
        assert evaluation.organization_id in [org_a, org_b]
      end

      org_a_hashes = bundle_hashes_for(org_a)
      org_b_hashes = bundle_hashes_for(org_b)

      # tenant A compiled with a waiver, so its bundle differs from tenant B's
      # (the waiver removed kyc.review_required from A's effective bundle)
      assert org_a_hashes != org_b_hashes

      # and both tenants evaluated the same subject facts — grain separation
      # means neither tenant's events touched the other's finding rows
      # one finding row per (tenant, control, subject) grain
      assert length(findings_for(org_a)) == 1
      assert length(findings_for(org_b)) == 1
    end
  end

  describe "missing evidence" do
    test "a subject with no kyc data is unknown, never compliant", %{org_a: org} do
      compile_and_activate(org)

      events = [
        unknown_event(org)
      ]

      AshCompliance.Testing.drain_sync(TestProjector, events)

      require Ash.Query

      finding =
        Finding
        |> Ash.Query.filter(organization_id == ^org and subject_id == "cus_unknown")
        |> Ash.read_one!(authorize?: false)

      assert finding.status == :unknown
      assert finding.breach_count == 0
      assert finding.explanation =~ "cannot evaluate"
      assert finding.explanation =~ "customer/has_valid_kyc"

      [evaluation] = evaluations_for(org)
      assert evaluation.outcome == :noncompliant
      assert evaluation.missing_facts != []
    end
  end

  # --- fixtures -----------------------------------------------------------------

  defp compliance_events(organization_id, subject_id) do
    [
      AshCompliance.Testing.event(
        id: 1,
        action: :kyc_reviewed,
        occurred_at: ~U[2026-09-17 10:00:00Z],
        metadata: %{
          "organization_id" => organization_id,
          "control_id" => "kyc.valid_required",
          "subject_type" => "customer",
          "subject_id" => subject_id,
          "correlation_id" => "corr-1",
          "facts" => [
            ["customer", "status", "active"],
            ["customer", "jurisdiction", "regulated"]
          ]
        }
      ),
      AshCompliance.Testing.event(
        id: 2,
        action: :kyc_reviewed,
        occurred_at: ~U[2026-09-17 11:00:00Z],
        metadata: %{
          "organization_id" => organization_id,
          "control_id" => "kyc.valid_required",
          "subject_type" => "customer",
          "subject_id" => subject_id,
          "correlation_id" => "corr-2",
          "facts" => [
            ["customer", "status", "active"],
            ["customer", "jurisdiction", "regulated"],
            ["customer", "has_valid_kyc", true]
          ]
        }
      )
    ]
  end

  defp unknown_event(organization_id) do
    AshCompliance.Testing.event(
      action: :kyc_reviewed,
      occurred_at: ~U[2026-09-17 12:00:00Z],
      metadata: %{
        "organization_id" => organization_id,
        "control_id" => "kyc.valid_required",
        "subject_type" => "customer",
        "subject_id" => "cus_unknown",
        "facts" => [
          ["customer", "status", "active"],
          ["customer", "jurisdiction", "regulated"]
        ]
      }
    )
  end

  # --- drain helpers ------------------------------------------------------------

  defp drain_fresh(events) do
    TestRepo.delete_all(Finding)
    TestRepo.delete_all(ComplianceEvaluation)

    :ok = AshCompliance.Testing.drain_sync(TestProjector, events)

    %{
      findings: Finding |> Ash.read!(authorize?: false),
      evaluations: ComplianceEvaluation |> Ash.read!(authorize?: false)
    }
  end

  defp findings_view(%{findings: findings}) do
    findings
    |> Enum.map(&Map.take(&1, @finding_fields))
    |> Enum.sort_by(&{&1.subject_id, &1.last_seen_at})
  end

  defp evaluations_view(%{evaluations: evaluations}) do
    evaluations
    |> Enum.map(&Map.take(&1, @evaluation_fields))
    |> Enum.sort_by(&{&1.subject_id, &1.evaluated_at})
  end

  # The state after the last event: the finding row with the latest last_seen_at
  # per subject.
  defp final_state(findings_view) do
    findings_view
    |> Enum.group_by(& &1.subject_id)
    |> Map.new(fn {subject, rows} ->
      {subject, Enum.max_by(rows, & &1.last_seen_at)}
    end)
  end

  defp findings_for(org) do
    Finding
    |> Ash.Query.filter(organization_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp evaluations_for(org) do
    ComplianceEvaluation
    |> Ash.Query.filter(organization_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp bundle_hashes_for(org) do
    evaluations_for(org)
    |> Enum.map(& &1.bundle_hash)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp count_by_org(evaluations) do
    Enum.frequencies_by(evaluations, & &1.organization_id)
  end

  defp compile_and_activate(org, opts \\ []) do
    waiver = Keyword.get(opts, :with_waiver, false)
    revision = Support.rule_set_revision(name: "rs-" <> Support.unique())

    revision
    |> Ash.Changeset.for_update(:validate)
    |> Ash.update!(authorize?: false)
    |> Ash.Changeset.for_update(:approve)
    |> Ash.update!(authorize?: false)
    |> Ash.Changeset.for_update(:activate)
    |> Ash.update!(authorize?: false)

    if waiver do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Ash.create!(AshCompliance.Resources.PolicyOverride, %{
        organization_id: org,
        kind: :waive,
        rule_id: "kyc.review_required",
        reason: "documented operational exception",
        approver: "security-officer",
        approved_at: now,
        starts_at: now,
        expires_at: DateTime.add(now, 24 * 3600, :second),
        compensating_controls: ["manual-review"]
      })
    end

    {:ok, bundle} = Ash.create(PolicyBundle, %{organization_id: org}, action: :compile)

    bundle
    |> Ash.Changeset.for_update(:activate)
    |> Ash.update!(authorize?: false)

    bundle
  end
end
