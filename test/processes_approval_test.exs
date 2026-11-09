# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ProcessesApprovalTest do
  @moduledoc """
  A self-approval is refused and recorded; a permitted approval is recorded; an
  approval that cannot be recorded is not an approval.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.Processes.Approval
  alias AshCompliance.Resources.ApprovalAttempt
  alias AshCompliance.TestRepo

  @process "compliance.access_request"

  setup do
    %{org: Ecto.UUID.generate(), subject: "req-#{System.unique_integer([:positive])}"}
  end

  defp attrs(subject, overrides) do
    Map.merge(
      %{
        process_key: @process,
        subject_id: subject,
        requester_id: "alice",
        approver_id: "bob",
        delegators: []
      },
      Map.new(overrides)
    )
  end

  defp attempts(org, subject) do
    Approval.attempts_for!(org, @process, subject)
  end

  test "a different approver is permitted and the permit is recorded", %{org: org, subject: s} do
    assert {:ok, attempt} = Approval.decide(org, attrs(s, []))
    assert attempt.outcome == :permitted
    assert attempt.reason == "different_people"
    assert [%{id: id}] = attempts(org, s)
    assert id == attempt.id
  end

  test "requester equals approver is refused and recorded", %{org: org, subject: s} do
    assert {:error, {:refused, "self_approval", attempt}} =
             Approval.decide(org, attrs(s, approver_id: "alice"))

    assert attempt.outcome == :refused
    assert attempt.requester_id == "alice"
    assert attempt.approver_id == "alice"
    assert [%{outcome: :refused, reason: "self_approval"}] = attempts(org, s)
  end

  test "requester equals approver through a delegation is refused and recorded",
       %{org: org, subject: s} do
    assert {:error, {:refused, "delegated_self_approval", attempt}} =
             Approval.decide(org, attrs(s, delegators: ["alice"]))

    assert attempt.delegation_chain == ["alice"]
    assert [%{outcome: :refused, delegation_chain: ["alice"]}] = attempts(org, s)
  end

  test "an unrecorded delegation chain is refused and the gap is recorded", %{
    org: org,
    subject: s
  } do
    assert {:error, {:refused, "delegation_unknown", attempt}} =
             Approval.decide(org, attrs(s, delegators: nil))

    refute attempt.delegation_recorded?
  end

  test "missing requester or approver is refused and recorded", %{org: org, subject: s} do
    assert {:error, {:refused, "requester_unknown", _}} =
             Approval.decide(org, attrs(s, requester_id: nil))

    assert {:error, {:refused, "approver_unknown", _}} =
             Approval.decide(org, attrs(s, approver_id: ""))

    assert length(attempts(org, s)) == 2
  end

  test "a refusal is returned as a refusal even when it cannot be recorded", %{subject: s} do
    assert {:error, {:refused, "self_approval", nil}} =
             Approval.decide("not-a-uuid", attrs(s, approver_id: "alice"))
  end

  test "a permit that cannot be recorded is not an approval", %{subject: s} do
    assert {:error, {:unrecorded, _}} = Approval.decide("not-a-uuid", attrs(s, []))
  end

  test "attempts cannot be edited or removed through the resource" do
    actions = ApprovalAttempt |> Ash.Resource.Info.actions() |> Enum.map(& &1.type)
    refute :update in actions
    refute :destroy in actions
  end

  test "attempts cannot be edited or removed in the database", %{org: org, subject: s} do
    {:ok, attempt} = Approval.decide(org, attrs(s, []))
    id = Ecto.UUID.dump!(attempt.id)

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      TestRepo.query!(
        "UPDATE ash_compliance_approval_attempts SET outcome = 'refused' WHERE id = $1",
        [id]
      )
    end
  end
end
