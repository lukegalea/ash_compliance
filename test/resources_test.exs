# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ResourcesTest do
  @moduledoc """
  Data-plane resource contracts: immutability of evidence, append-only
  evaluations, and the control mapping seam.
  """

  use AshCompliance.DataCase, async: true

  require Ash.Query

  @org Ecto.UUID.generate()
  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  describe "EvidenceArtifact" do
    test "creates with hash, method and custody chain" do
      {:ok, artifact} =
        Ash.create(AshCompliance.Resources.EvidenceArtifact, %{
          organization_id: @org,
          control_id: "kyc.valid_required",
          subject_type: "customer",
          subject_id: "cus_1",
          hash: String.duplicate("ab", 32),
          media_type: "application/pdf",
          collector: "kyc-vendor",
          method: :examine,
          chain_of_custody: [
            %{"at" => "2026-09-17T12:00:00Z", "actor" => "collector", "action" => "collected"}
          ],
          retention_class: "7y",
          collected_at: @now
        })

      assert artifact.method == :examine
      assert artifact.hash == String.duplicate("ab", 32)
    end

    test "is immutable: no update or destroy actions exist" do
      actions =
        Ash.Resource.Info.actions(AshCompliance.Resources.EvidenceArtifact)
        |> Enum.map(& &1.name)

      refute :update in actions
      refute :destroy in actions
    end

    test "an unknown assessment method is refused" do
      assert {:error, _} =
               Ash.create(AshCompliance.Resources.EvidenceArtifact, %{
                 organization_id: @org,
                 control_id: "kyc.valid_required",
                 hash: String.duplicate("cd", 32),
                 media_type: "text/plain",
                 collector: "auditor",
                 method: :vibes,
                 collected_at: @now
               })
    end
  end

  describe "ComplianceEvaluation" do
    test "is append-only: create and read, no updates" do
      {:ok, evaluation} =
        Ash.create(AshCompliance.Resources.ComplianceEvaluation, %{
          organization_id: @org,
          control_id: "kyc.valid_required",
          subject_type: "customer",
          subject_id: "cus_1",
          bundle_hash: String.duplicate("ef", 32),
          evaluator: "AshRules.Evaluator.Direct",
          outcome: :unknown,
          fact_snapshot_hash: String.duplicate("ab", 32),
          missing_facts: ["customer/has_valid_kyc"],
          correlation_id: "corr-9",
          source_event_id: "42",
          evaluated_at: @now
        })

      assert evaluation.outcome == :unknown

      actions =
        Ash.Resource.Info.actions(AshCompliance.Resources.ComplianceEvaluation)
        |> Enum.map(& &1.name)

      refute :update in actions
      refute :destroy in actions
    end
  end

  describe "ControlMapping" do
    test "maps a gap to a control per organization" do
      {:ok, mapping} =
        Ash.create(AshCompliance.Resources.ControlMapping, %{
          organization_id: @org,
          gap: "kyc.valid_required",
          control_id: "kyc.valid_required",
          jurisdiction: "regulated",
          notes: "primary filing"
        })

      assert mapping.gap == "kyc.valid_required"

      mappings =
        AshCompliance.Resources.ControlMapping
        |> Ash.Query.filter(organization_id == ^@org and gap == "kyc.valid_required")
        |> Ash.read!(authorize?: false)

      assert length(mappings) == 1
    end
  end
end
