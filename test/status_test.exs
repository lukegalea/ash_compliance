# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.StatusTest do
  @moduledoc """
  `AshCompliance.status_for/2` — record-level compliance status on the
  appointment weight story: weight recorded → compliant; weight missing →
  noncompliant with the rule's gap text; a rule whose subject doesn't match →
  not_applicable; no active bundle → the distinct error contract.
  """

  use AshCompliance.DataCase, async: true

  alias AshCompliance.Test.{Appointment, AppointmentFacts, RuleSets, Support}

  @org Ecto.UUID.generate()

  setup do
    activate_appointment_bundle()
    :ok
  end

  test "a record with the weight recorded is compliant" do
    record = %Appointment{id: Ecto.UUID.generate(), weight_kg: 72.5}

    assert {:ok, status} =
             AshCompliance.status_for(record,
               organization: @org,
               fact_builder: AppointmentFacts,
               transition_to: :checked_in
             )

    assert status.status == :compliant

    verdict = verdict_for(status, "appt.checkin_requires_weight")

    assert verdict.status == :compliant
    assert verdict.severity == :high
    assert verdict.gap == "record the patient's weight before check-in"

    assert status.bundle_hash =~ ~r/^[0-9a-f]{64}$/
    assert is_binary(status.bundle_revision)
  end

  test "a record without a recorded weight is noncompliant, quoting the gap text" do
    record = %Appointment{id: Ecto.UUID.generate()}

    assert {:ok, status} =
             AshCompliance.status_for(record,
               organization: @org,
               fact_builder: AppointmentFacts,
               transition_to: :checked_in
             )

    assert status.status == :noncompliant

    verdict = verdict_for(status, "appt.checkin_requires_weight")

    assert verdict.status == :noncompliant
    assert verdict.severity == :high
    assert verdict.gap == "record the patient's weight before check-in"

    # The guard's refusal vocabulary, ready for a surface to quote: gap text
    # filed under the rule id that produced it.
    assert AshCompliance.Status.message(status) ==
             "compliance: record the patient's weight before check-in " <>
               "(appt.checkin_requires_weight)"
  end

  test "a rule whose subject does not match is not_applicable" do
    record = %Appointment{
      id: Ecto.UUID.generate(),
      weight_kg: 72.5,
      triage_urgency: :urgent,
      notes: "seen and documented"
    }

    assert {:ok, status} =
             AshCompliance.status_for(record,
               organization: @org,
               fact_builder: AppointmentFacts,
               transition_to: :completed
             )

    # The check-in weight rule gates on :checked_in; this record is heading to
    # :completed, so the rule stands aside rather than firing.
    assert verdict_for(status, "appt.checkin_requires_weight").status == :not_applicable
    assert verdict_for(status, "appt.complete_requires_triage").status == :compliant
    assert verdict_for(status, "appt.complete_requires_notes").status == :compliant

    assert status.status == :compliant
    assert AshCompliance.Status.message(status) == nil
  end

  test "no active bundle is a distinct error, not a status" do
    assert {:error, :no_active_bundle} =
             AshCompliance.status_for(%Appointment{id: Ecto.UUID.generate()},
               organization: Ecto.UUID.generate(),
               fact_builder: AppointmentFacts,
               transition_to: :checked_in
             )
  end

  # --- wiring variants ------------------------------------------------------------

  test "the record's own module can be the fact builder" do
    assert {:ok, status} =
             AshCompliance.status_for(%Appointment{id: Ecto.UUID.generate()},
               organization: @org,
               transition_to: :checked_in
             )

    assert status.status == :noncompliant
  end

  test "the organization may arrive as the established MFA" do
    record = %Appointment{id: Ecto.UUID.generate(), weight_kg: 72.5}

    assert {:ok, status} =
             AshCompliance.status_for(record,
               organization: {__MODULE__, :organization_id, []},
               fact_builder: AppointmentFacts,
               transition_to: :checked_in
             )

    assert status.status == :compliant
  end

  def organization_id, do: @org

  test "explicit :facts bypass the fact builder" do
    assert {:ok, status} =
             AshCompliance.status_for(%Appointment{id: Ecto.UUID.generate()},
               organization: @org,
               facts: [
                 {"appointment", :transition_to, :checked_in},
                 {"appointment", :patient_weight_recorded, true}
               ]
             )

    assert status.status == :compliant

    assert status.facts == [
             {"appointment", :transition_to, :checked_in},
             {"appointment", :patient_weight_recorded, true}
           ]
  end

  test "a pre-fetched PolicyBundle bypasses the active-bundle read" do
    bundle = AshCompliance.Domain.active_policy_bundle!(@org, authorize?: false)

    assert {:ok, status} =
             AshCompliance.status_for(%Appointment{id: Ecto.UUID.generate()},
               bundle: bundle,
               fact_builder: AppointmentFacts,
               transition_to: :checked_in
             )

    assert status.status == :noncompliant
    assert status.bundle_hash == bundle.content_hash
  end

  test "a pre-decoded AshRules.Ir.Bundle bypasses both reads" do
    assert {:ok, status} =
             AshCompliance.status_for(%Appointment{id: Ecto.UUID.generate(), weight_kg: 72.5},
               bundle: decoded_appointment_bundle(),
               fact_builder: AppointmentFacts,
               transition_to: :checked_in
             )

    assert status.status == :compliant
  end

  test "a capture can be the fact builder" do
    facts = fn _record ->
      [
        {"appointment", :transition_to, :checked_in},
        {"appointment", :patient_weight_recorded, false}
      ]
    end

    assert {:ok, status} =
             AshCompliance.status_for(%Appointment{id: Ecto.UUID.generate()},
               organization: @org,
               fact_builder: facts
             )

    assert status.status == :noncompliant
  end

  # --- the failure contracts --------------------------------------------------------

  test "a missing :organization is a caller error, stated plainly" do
    assert_raise ArgumentError, ~r/:organization/, fn ->
      AshCompliance.status_for(%Appointment{id: Ecto.UUID.generate()},
        fact_builder: AppointmentFacts,
        transition_to: :checked_in
      )
    end
  end

  test "no resolvable fact builder is a distinct error" do
    assert {:error, :no_fact_builder} =
             AshCompliance.status_for(%{not: :a_struct_with_a_builder},
               organization: @org,
               transition_to: :checked_in
             )
  end

  test "facts outside the bundle's schema fail the evaluation, naming the fix" do
    assert {:error, message} =
             AshCompliance.status_for(%Appointment{id: Ecto.UUID.generate()},
               bundle: decoded_appointment_bundle(),
               facts: [{"appointment", :not_in_the_schema, true}]
             )

    assert message =~ "not_in_the_schema"
    assert message =~ "fact_schema"
  end

  # A decoded bundle, as hosts hold one (decoded from the stored rules_json,
  # post-JSON round-trip: subject atoms arrive back as strings — exactly the
  # spelling the fact-builder contract emits).
  defp decoded_appointment_bundle do
    {:ok, decoded} =
      RuleSets.AppointmentRules.__bundle__()
      |> AshRules.Ir.encode!()
      |> AshRules.Ir.decode()

    decoded
  end

  defp activate_appointment_bundle do
    bundle_module = RuleSets.AppointmentRules

    revision =
      Support.rule_set_revision(
        name: "appointments-" <> Support.unique(),
        rules_json: Support.bundle_json(bundle_module),
        content_hash: bundle_module.__bundle__().content_hash
      )

    revision
    |> AshCompliance.Domain.validate_rule_set_revision!(authorize?: false)
    |> AshCompliance.Domain.approve_rule_set_revision!(authorize?: false)
    |> AshCompliance.Domain.activate_rule_set_revision!(authorize?: false)

    AshCompliance.Domain.compile_policy_bundle!(%{organization_id: @org}, authorize?: false)
    |> AshCompliance.Domain.activate_policy_bundle!(authorize?: false)

    :ok
  end

  defp verdict_for(status, rule_id) do
    Enum.find(status.rules, &(&1.rule_id == rule_id))
  end
end
