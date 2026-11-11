# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ProcessesCompletionTest do
  @moduledoc """
  Completing a process writes evidence through the evidence writer, and the
  freshness evaluator counts it only for the collector the control row declares.
  Anything short of a finished, approved instance writes nothing.
  """

  use AshCompliance.DataCase, async: false

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Domain
  alias AshCompliance.Ownership.Evidence
  alias AshCompliance.Ownership.Freshness
  alias AshCompliance.Processes.{Approval, Completion, Templates}

  @collector "file:priv/processes/access_request.bpmn"
  @now ~U[2026-11-10 12:00:00.000000Z]

  setup do
    %{org: Ecto.UUID.generate(), instance: "inst-#{System.unique_integer([:positive])}"}
  end

  defp approve!(org, instance, template \\ "access_request") do
    {:ok, _} =
      Approval.decide(org, %{
        process_key: "compliance." <> template,
        subject_id: instance,
        requester_id: "alice",
        approver_id: "bob",
        delegators: []
      })
  end

  defp attrs(instance, overrides \\ []) do
    Map.merge(
      %{instance_id: instance, completed_by: "bob", outcome: "completed", summary: %{"n" => 1}},
      Map.new(overrides)
    )
  end

  defp complete(org, template, attrs, opts \\ []) do
    Completion.complete(
      org,
      template,
      attrs,
      Keyword.merge([collector: @collector, now: @now], opts)
    )
  end

  defp artifacts(org, control), do: Domain.evidence_for_control!(org, control, authorize?: false)

  test "completion writes one artifact per criterion, named by the collector", %{
    org: org,
    instance: i
  } do
    approve!(org, i)
    assert {:ok, written} = complete(org, "access_request", attrs(i))
    assert length(written) == 3

    for criterion <- Templates.get("access_request").criteria do
      assert [artifact] = artifacts(org, criterion)
      assert artifact.collector == @collector
      assert artifact.subject_type == "process_instance"
      assert artifact.subject_id == i
      assert artifact.media_type == "application/json"
      assert byte_size(artifact.hash) == 64
    end
  end

  test "approvals_organization_id files the evidence under one organization and finds the approval in another",
       %{org: org, instance: i} do
    operator_org = Ecto.UUID.generate()
    approve!(org, i)

    assert {:error, :no_recorded_approval} = complete(operator_org, "access_request", attrs(i))

    assert {:ok, written} =
             complete(operator_org, "access_request", attrs(i),
               approvals_organization_id: org,
               store_content: true
             )

    assert Enum.all?(
             written,
             &(&1.organization_id == operator_org and Evidence.verify(&1) == :ok)
           )

    assert artifacts(org, "CC6.2") == []
  end

  test "the artifact content pins the template, the approvals and the summary", %{
    org: org,
    instance: i
  } do
    {:ok, attempt} = approve!(org, i)
    {:ok, [artifact | _]} = complete(org, "access_request", attrs(i))

    content =
      AshCompliance.Processes.Canonical.encode!(%{
        "process" => "compliance.access_request",
        "template_hash" => Templates.content_hash("access_request"),
        "criterion" => artifact_criterion(artifact),
        "instance_id" => i,
        "completed_by" => "bob",
        "outcome" => "completed",
        "approvals" => [attempt.id],
        "summary" => %{"n" => 1}
      })

    assert artifact.hash == AshCompliance.Ownership.Evidence.sha256(content)
  end

  defp artifact_criterion(artifact), do: artifact.control_id

  test "the evidence makes a control's process source fresh, and only for that collector",
       %{org: org, instance: i} do
    approve!(org, i)
    {:ok, _} = complete(org, "access_request", attrs(i))

    row =
      row("CC6.1", %{
        "operating_process" => @collector,
        "evidence_producer" => nil,
        "frequency" => "daily"
      })

    mine = artifacts(org, "CC6.1")
    assert %{state: :evidenced} = Freshness.evaluate_row("CC6.1", row, mine, @now)

    other = %{row | "operating_process" => "file:priv/processes/other.bpmn"}

    assert %{state: :unknown, reason: :no_evidence} =
             Freshness.evaluate_row("CC6.1", other, mine, @now)
  end

  describe "nothing is written" do
    test "for an outcome that is not completed", %{org: org, instance: i} do
      approve!(org, i)

      for outcome <- [
            "rejected",
            "refused",
            "not_completed",
            "recorded_only",
            "expired",
            "",
            nil,
            :completed
          ] do
        assert {:error, {:not_completed, _}} =
                 complete(org, "access_request", attrs(i, outcome: outcome))
      end

      assert artifacts(org, "CC6.1") == []
    end

    test "without any recorded approval", %{org: org, instance: i} do
      assert {:error, :no_recorded_approval} = complete(org, "access_request", attrs(i))
      assert artifacts(org, "CC6.1") == []
    end

    test "when the only approval attempt was a refused self-approval", %{org: org, instance: i} do
      {:error, {:refused, _, _}} =
        Approval.decide(org, %{
          process_key: "compliance.access_request",
          subject_id: i,
          requester_id: "alice",
          approver_id: "alice",
          delegators: []
        })

      assert {:error, :no_recorded_approval} = complete(org, "access_request", attrs(i))
      assert artifacts(org, "CC6.1") == []
    end

    test "when the approval was for a different instance", %{org: org, instance: i} do
      approve!(org, "someone-else")
      assert {:error, :no_recorded_approval} = complete(org, "access_request", attrs(i))
    end

    test "when the approval was for a different process", %{org: org, instance: i} do
      approve!(org, i, "break_glass")
      assert {:error, :no_recorded_approval} = complete(org, "access_request", attrs(i))
    end

    test "without an instance, a completer or a collector", %{org: org, instance: i} do
      approve!(org, i)

      for bad <- [nil, "", "  ", 7] do
        assert {:error, {:missing, :instance_id}} =
                 complete(org, "access_request", attrs(i, instance_id: bad))

        assert {:error, {:missing, :completed_by}} =
                 complete(org, "access_request", attrs(i, completed_by: bad))
      end

      assert {:error, :no_producer} = complete(org, "access_request", attrs(i), collector: nil)
      assert {:error, :no_producer} = complete(org, "access_request", attrs(i), collector: " ")
      assert artifacts(org, "CC6.1") == []
    end

    test "for an unknown template or a malformed organization or summary", %{
      org: org,
      instance: i
    } do
      approve!(org, i)
      assert {:error, {:unknown_template, "nope"}} = complete(org, "nope", attrs(i))

      assert {:error, :invalid_organization} =
               complete("not-a-uuid", "log_alert_review", attrs(i))

      assert {:error, :summary_not_a_map} =
               complete(org, "access_request", attrs(i, summary: [1]))

      assert {:error, :summary_not_encodable} =
               complete(org, "access_request", attrs(i, summary: %{"p" => self()}))

      assert artifacts(org, "CC6.1") == []
    end

    test "dated in the future", %{org: org, instance: i} do
      approve!(org, i)

      assert {:error, :future_dated} =
               complete(org, "access_request", attrs(i),
                 collected_at: DateTime.add(@now, 3600, :second)
               )
    end
  end

  test "a template with no approval needs none", %{org: org, instance: i} do
    assert {:ok, [artifact]} =
             complete(org, "log_alert_review", attrs(i, completed_by: "carol"),
               collector: "file:priv/processes/log_alert_review.bpmn"
             )

    assert artifact.control_id == "CC7.2"
  end
end
