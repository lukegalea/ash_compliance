# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ApprovalRecordsAuthorizationTest do
  @moduledoc """
  An approval attempt records the decision's answer, never the caller's, and
  neither an attempt nor an override can be written by an actor.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.Domain
  alias AshCompliance.Processes.Approval

  @process "compliance.access_request"

  setup do
    %{org: Ecto.UUID.generate(), subject: "req-#{System.unique_integer([:positive])}"}
  end

  defp attempt(org, subject, overrides \\ []) do
    Map.merge(
      %{
        organization_id: org,
        process_key: @process,
        subject_id: subject,
        requester_id: "alice",
        approver_id: "alice",
        delegation_chain: [],
        delegation_recorded?: true
      },
      Map.new(overrides)
    )
  end

  defp waiver(org) do
    now = DateTime.utc_now()

    %{
      organization_id: org,
      kind: :waive,
      rule_id: "kyc.review_required",
      reason: "documented operational exception",
      approver: "security-officer",
      requested_by: "ops-engineer",
      approved_at: now,
      starts_at: now,
      expires_at: DateTime.add(now, 7 * 86_400, :second),
      compensating_controls: ["manual-review"]
    }
  end

  defp actor, do: %{id: Ecto.UUID.generate()}

  describe "an approval attempt" do
    test "refuses a caller-supplied outcome", %{org: org, subject: s} do
      forged =
        attempt(org, s, outcome: :permitted, reason: "different_people", decision_hash: "x")

      assert {:error, %Ash.Error.Invalid{}} =
               Domain.record_approval_attempt(forged, authorize?: false)

      assert Approval.attempts_for!(org, @process, s) == []
    end

    test "records the decision's refusal for a self-approval", %{org: org, subject: s} do
      assert {:ok, row} = Domain.record_approval_attempt(attempt(org, s), authorize?: false)
      assert row.outcome == :refused
      assert row.reason == "self_approval"
    end

    test "records a refusal when the chain was not recorded", %{org: org, subject: s} do
      attrs = attempt(org, s, approver_id: "bob", delegation_recorded?: false)

      assert {:ok, %{outcome: :refused, reason: "delegation_unknown"}} =
               Domain.record_approval_attempt(attrs, authorize?: false)
    end

    test "cannot be written by an actor, or with no actor", %{org: org, subject: s} do
      attrs = attempt(org, s, approver_id: "bob")

      assert {:error, %Ash.Error.Forbidden{}} =
               Domain.record_approval_attempt(attrs, actor: actor())

      assert {:error, %Ash.Error.Forbidden{}} = Domain.record_approval_attempt(attrs)
      assert Approval.attempts_for!(org, @process, s) == []
    end

    test "can be read by an actor", %{org: org, subject: s} do
      {:ok, _} =
        Approval.decide(org, %{
          process_key: @process,
          subject_id: s,
          requester_id: "alice",
          approver_id: "bob",
          delegators: []
        })

      assert {:ok, [%{outcome: :permitted}]} =
               Approval.attempts_for(org, @process, s, actor: actor(), authorize?: true)
    end
  end

  describe "a policy override" do
    test "cannot be created by an actor", %{org: org} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Domain.create_policy_override(waiver(org), actor: actor())

      assert {:ok, []} =
               Domain.valid_policy_overrides(org, DateTime.utc_now(), authorize?: false)
    end

    test "cannot be destroyed by an actor", %{org: org} do
      override = Domain.create_policy_override!(waiver(org), authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(override, actor: actor())

      assert {:ok, [%{id: id}]} =
               Domain.valid_policy_overrides(org, DateTime.utc_now(),
                 actor: actor(),
                 authorize?: true
               )

      assert id == override.id
    end
  end
end
