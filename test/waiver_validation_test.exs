# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.WaiverValidationTest do
  @moduledoc """
  Waivers are bounded time + scope + accountability. The validations make an
  unaccountable waiver impossible to construct.
  """

  use AshCompliance.DataCase, async: true

  @org Ecto.UUID.generate()
  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp base_attrs do
    %{
      organization_id: @org,
      kind: :waive,
      rule_id: "kyc.review_required",
      reason: "documented operational exception",
      approver: "security-officer",
      requested_by: "ops-engineer",
      approved_at: @now,
      starts_at: @now,
      expires_at: DateTime.add(@now, 7 * 86_400, :second),
      compensating_controls: ["manual-review"]
    }
  end

  test "a fully-specified waiver is accepted" do
    assert {:ok, _} = AshCompliance.Domain.create_policy_override(base_attrs(), authorize?: false)
  end

  test "an open-ended waiver (no expires_at) is refused" do
    attrs = Map.delete(base_attrs(), :expires_at)

    assert {:error, errors} =
             AshCompliance.Domain.create_policy_override(attrs, authorize?: false)

    assert Enum.any?(errors.errors, &(&1.message =~ "bounded time"))
  end

  test "an expires_at before starts_at is refused" do
    attrs =
      Map.merge(base_attrs(), %{
        starts_at: DateTime.add(@now, 48 * 3600, :second),
        expires_at: DateTime.add(@now, 24 * 3600, :second)
      })

    assert {:error, errors} =
             AshCompliance.Domain.create_policy_override(attrs, authorize?: false)

    assert Enum.any?(errors.errors, &(&1.message =~ "must be after its starts_at"))
  end

  test "a waiver without compensating controls is refused" do
    attrs = Map.put(base_attrs(), :compensating_controls, [])

    assert {:error, errors} =
             AshCompliance.Domain.create_policy_override(attrs, authorize?: false)

    assert Enum.any?(errors.errors, &(&1.message =~ "compensating_controls"))
  end

  test "a waiver without an approver is refused" do
    attrs = Map.put(base_attrs(), :approver, "")

    assert {:error, errors} =
             AshCompliance.Domain.create_policy_override(attrs, authorize?: false)

    assert Enum.any?(errors.errors, &(&1.message =~ "named approver"))
  end

  test "a replacement without a replacement rule set is refused" do
    attrs =
      Map.merge(base_attrs(), %{
        kind: :replace,
        expires_at: nil,
        compensating_controls: []
      })

    assert {:error, errors} =
             AshCompliance.Domain.create_policy_override(attrs, authorize?: false)

    assert Enum.any?(errors.errors, &(&1.message =~ "replacement_rules_json"))
  end

  describe "separation of duties" do
    test "an approver who is the requester is refused, however it is spelled" do
      for requester <- ["security-officer", " Security-Officer "] do
        attrs = Map.put(base_attrs(), :requested_by, requester)

        assert {:error, errors} =
                 AshCompliance.Domain.create_policy_override(attrs, authorize?: false)

        assert Enum.any?(errors.errors, &(&1.message =~ "one person and approved by another"))
      end
    end

    test "a missing requester is refused" do
      for requester <- [nil, "", "  "] do
        attrs = Map.put(base_attrs(), :requested_by, requester)

        assert {:error, _} =
                 AshCompliance.Domain.create_policy_override(attrs, authorize?: false)
      end

      assert {:error, _} =
               AshCompliance.Domain.create_policy_override(
                 Map.delete(base_attrs(), :requested_by),
                 authorize?: false
               )
    end

    test "a replacement is held to the same rule" do
      attrs =
        Map.merge(base_attrs(), %{
          kind: :replace,
          expires_at: nil,
          compensating_controls: [],
          replacement_rules_json: "{}",
          requested_by: "security-officer"
        })

      assert {:error, _} = AshCompliance.Domain.create_policy_override(attrs, authorize?: false)
    end
  end
end
