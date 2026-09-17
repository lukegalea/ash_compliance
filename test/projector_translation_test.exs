# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ProjectorTranslationTest do
  @moduledoc """
  Unit tests for the evaluator-to-ops translation: one event plus a current
  finding row yields the exact ops the finding projection needs.
  """

  use AshCompliance.DataCase, async: true

  alias AshCompliance.Projector
  alias AshCompliance.Test.RuleSets.GlobalBaseline
  alias AshCompliance.Test.Support

  # Production evaluates the *decoded* bundle from the PolicyBundle's stored
  # JSON, where subjects are strings (the opaque wire form) — not the
  # in-memory DSL bundle.
  @bundle AshRules.Ir.decode!(Support.bundle_json(GlobalBaseline))
  @org Ecto.UUID.generate()
  @control "kyc.valid_required"
  @now DateTime.from_iso8601("2026-09-17T12:00:00Z") |> elem(1)

  defp event(metadata_overrides \\ %{}) do
    AshCompliance.Testing.event(
      action: :kyc_reviewed,
      occurred_at: @now,
      metadata:
        Map.merge(
          %{
            "organization_id" => @org,
            "control_id" => @control,
            "subject_type" => "customer",
            "subject_id" => "cus_1",
            "correlation_id" => "corr-1",
            "facts" => [
              ["customer", "status", "active"],
              ["customer", "jurisdiction", "regulated"]
            ]
          },
          metadata_overrides
        )
    )
  end

  defp finding_row(status \\ :unknown) do
    %AshCompliance.Resources.Finding{
      organization_id: @org,
      control_id: @control,
      subject_type: "customer",
      subject_id: "cus_1",
      status: status,
      breach_count: 0
    }
  end

  test "a fully-known compliant subject yields compliant ops with no breach" do
    metadata = %{
      "facts" => [
        ["customer", "status", "active"],
        ["customer", "jurisdiction", "regulated"],
        ["customer", "has_valid_kyc", true],
        ["customer", "reviewed", true]
      ]
    }

    {:ok, ops} = Projector.translate(event(metadata), finding_row(:unknown), @bundle, [])

    assert {:set, :status, :compliant} in ops
    assert {:set, :first_seen_at, @now} in ops
    assert {:set, :resolved_at, @now} not in ops
    refute Enum.any?(ops, &match?({:increment, :breach_count, 1}, &1))
    assert {:set, :last_seen_at, @now} in ops
    assert {:set, :bundle_hash, @bundle.content_hash} in ops
  end

  test "a violation yields noncompliant ops with a breach increment" do
    metadata = %{
      "facts" => [
        ["customer", "status", "active"],
        ["customer", "jurisdiction", "regulated"],
        ["customer", "has_valid_kyc", false],
        ["customer", "reviewed", true]
      ]
    }

    current = %AshCompliance.Resources.Finding{
      finding_row(:compliant)
      | resolved_at: DateTime.from_iso8601("2026-08-01T00:00:00Z") |> elem(1)
    }

    {:ok, ops} = Projector.translate(event(metadata), current, @bundle, [])

    assert {:set, :status, :noncompliant} in ops
    assert {:increment, :breach_count, 1} in ops
    assert {:set, :resolved_at, nil} in ops

    {:set, :explanation, explanation} = Enum.find(ops, &match?({:set, :explanation, _}, &1))
    assert explanation =~ "requires valid KYC"
  end

  test "missing unknown-semantics facts yield unknown, never compliant" do
    {:ok, ops} = Projector.translate(event(), finding_row(:compliant), @bundle, [])

    assert {:set, :status, :unknown} in ops
    refute Enum.any?(ops, &match?({:increment, :breach_count, 1}, &1))

    {:set, :explanation, explanation} = Enum.find(ops, &match?({:set, :explanation, _}, &1))
    assert explanation =~ "cannot evaluate"
    assert explanation =~ "customer/has_valid_kyc"
  end

  test "a noncompliant-to-compliant transition stamps resolved_at" do
    metadata = %{
      "facts" => [
        ["customer", "status", "active"],
        ["customer", "jurisdiction", "regulated"],
        ["customer", "has_valid_kyc", true],
        ["customer", "reviewed", true]
      ]
    }

    current = %AshCompliance.Resources.Finding{
      finding_row(:noncompliant)
      | resolved_at: nil,
        first_seen_at: @now
    }

    {:ok, ops} = Projector.translate(event(metadata), current, @bundle, [])
    assert {:set, :resolved_at, @now} in ops
  end

  test "first_seen_at is only emitted for a fresh row" do
    metadata = %{
      "facts" => [
        ["customer", "status", "active"],
        ["customer", "jurisdiction", "regulated"],
        ["customer", "has_valid_kyc", true],
        ["customer", "reviewed", true]
      ]
    }

    current = %AshCompliance.Resources.Finding{
      finding_row(:compliant)
      | first_seen_at: @now,
        last_seen_at: @now
    }

    {:ok, ops} = Projector.translate(event(metadata), current, @bundle, [])
    assert {:set, :first_seen_at, @now} not in ops
    assert {:set, :last_seen_at, @now} in ops
  end

  test "an unknown predicate in the payload yields error ops" do
    metadata = %{
      "facts" => [["customer", "nonsense", true]]
    }

    {:ok, ops} = Projector.translate(event(metadata), finding_row(), @bundle, [])

    assert {:set, :status, :error} in ops

    assert {:set, :explanation, explanation} =
             Enum.find(ops, &match?({:set, :explanation, _}, &1))

    assert explanation =~ "fact extraction failed"
    assert explanation =~ "nonsense"
  end

  test "a control with no rules filed under it is unknown, never compliant" do
    row = %{finding_row(:unknown) | control_id: "no.such.control"}
    {:ok, ops} = Projector.translate(event(), row, @bundle, [])

    assert {:set, :status, :unknown} in ops

    {:set, :explanation, explanation} = Enum.find(ops, &match?({:set, :explanation, _}, &1))
    assert explanation == "no rules are filed under this control"
  end

  test "the fact snapshot hash is stable and content-sensitive" do
    assert AshCompliance.Projector.Facts.snapshot_hash(event()) ==
             AshCompliance.Projector.Facts.snapshot_hash(event())

    changed = event(%{"facts" => [["customer", "status", "suspended"]]})

    refute AshCompliance.Projector.Facts.snapshot_hash(event()) ==
             AshCompliance.Projector.Facts.snapshot_hash(changed)
  end

  test "binary project_all names match existing atoms, never mint new ones" do
    # A declared action name that has no existing atom — a typo, or config
    # quoted out of somewhere it should not have come from — must skip with a
    # log, not grow the atom table. The atom is minted after this string is
    # built, so asserting it cannot be resolved back proves it was never
    # created by the projector.
    bogus = "compliance_no_such_action_#{System.unique_integer([:positive])}"

    projector =
      Module.concat(["AshCompliance.ProjectorEphemeral#{System.unique_integer([:positive])}"])

    source = """
    defmodule #{inspect(projector)} do
      use AshCompliance.Projector,
        name: "ephemeral_skip_v1",
        event_log: AshCompliance.Test.Events.Event,
        projection_resource: AshCompliance.Resources.Finding,
        bundle: {AshCompliance.Test.Projector, :active_bundle, []}

      project_all ["#{bogus}"]
    end
    """

    assert [{^projector, _bytecode}] = Code.compile_string(source, "#{projector}.ex")

    on_exit(fn ->
      :code.purge(projector)
      :code.delete(projector)
    end)

    # the binary was never turned into an atom
    assert_raise ArgumentError, fn -> String.to_existing_atom(bogus) end

    # and events fall through to the skip fallbacks, with no stateful clause
    assert projector.handle_event(%{action: :kyc_reviewed}) == :skip
    assert projector.needs_current_state?(%{action: :kyc_reviewed}) == false
  end
end
