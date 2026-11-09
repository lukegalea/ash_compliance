# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ProcessesSeparationOfDutiesTest do
  @moduledoc """
  The shipped separation decision, evaluated by the real engine. Every input
  that is not positively a different person is a refusal.
  """

  use ExUnit.Case, async: true

  alias AshCompliance.Processes.{Decisions, SeparationOfDuties}

  defp check(requester, approver, delegators \\ []),
    do: SeparationOfDuties.check(requester, approver, delegators)

  test "two different people with no delegation are permitted" do
    verdict = check("alice", "bob")
    assert verdict.outcome == :permit
    assert verdict.reason == "different_people"
    assert verdict.decision_hash == Decisions.content_hash("compliance.separation_of_duties")
    assert SeparationOfDuties.permit?(verdict)
  end

  test "a delegation chain that does not include the requester is permitted" do
    assert %{outcome: :permit} = check("alice", "bob", ["carol", "dave"])
  end

  describe "refusals" do
    test "requester equals approver" do
      assert %{outcome: :refuse, reason: "self_approval"} = check("alice", "alice")
    end

    test "requester equals approver through a delegation" do
      assert %{outcome: :refuse, reason: "delegated_self_approval"} =
               check("alice", "bob", ["alice"])
    end

    test "requester anywhere in a longer delegation chain" do
      assert %{outcome: :refuse, reason: "delegated_self_approval"} =
               check("alice", "bob", ["carol", "dave", "alice"])
    end

    test "two spellings of the same identifier count as one person" do
      assert %{outcome: :refuse, reason: "self_approval"} = check("Alice ", " alice")

      assert %{outcome: :refuse, reason: "delegated_self_approval"} =
               check("alice", "bob", ["ALICE"])
    end

    test "an unknown requester is never a pass" do
      for requester <- [nil, "", "   ", 42, :alice, %{}] do
        assert %{outcome: :refuse, reason: "requester_unknown"} = check(requester, "bob")
      end
    end

    test "an unknown approver is never a pass" do
      for approver <- [nil, "", "   ", 42, :bob] do
        assert %{outcome: :refuse, reason: "approver_unknown"} = check("alice", approver)
      end
    end

    test "an unrecorded delegation chain is never a pass" do
      for chain <- [nil, "alice", %{}, [1, 2], ["carol", nil]] do
        assert %{outcome: :refuse, reason: "delegation_unknown"} = check("alice", "bob", chain)
      end
    end

    test "two unknown principals are not equal people" do
      assert %{outcome: :refuse} = check(nil, nil)
    end
  end

  describe "an answer that is not a clean permit" do
    @hash "h"

    test "is refused whatever its shape" do
      for answer <- [
            nil,
            [],
            "permit",
            :permit,
            %{},
            %{"outcome" => "permit"},
            %{"outcome" => "permit", "reason" => nil},
            %{"outcome" => "maybe", "reason" => "x"},
            %{"outcome" => :permit, "reason" => "x"},
            [%{"outcome" => "permit", "reason" => "x"}]
          ] do
        assert %{outcome: :refuse} = SeparationOfDuties.interpret(answer, @hash)
      end
    end

    test "a refuse answer keeps the decision's reason" do
      assert %{outcome: :refuse, reason: "self_approval"} =
               SeparationOfDuties.interpret(
                 %{"outcome" => "refuse", "reason" => "self_approval"},
                 @hash
               )
    end
  end
end
