# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.Appointment do
  @moduledoc """
  A stand-in host record: an appointment-shaped struct carrying the weight,
  triage and notes the appointment rules probe.

  It implements `AshCompliance.FactBuilder` itself — the default-builder path
  of `AshCompliance.status_for/2`, keeping the contract next to the resource —
  and delegates to the standalone builder module so both wiring styles share
  one fact vocabulary.
  """

  defstruct [:id, :weight_kg, :triage_urgency, :notes]

  @behaviour AshCompliance.FactBuilder

  @impl true
  def facts(appointment, opts) do
    AshCompliance.Test.AppointmentFacts.facts(appointment, opts)
  end
end

defmodule AshCompliance.Test.AppointmentFacts do
  @moduledoc false

  # The guard-shaped builder (see clinic-demo's ComplianceGuard): string
  # subject — predicates travel through the control plane as JSON, where
  # subject terms are opaque — precomputed policy booleans rather than raw
  # storage, and transition context arriving through the opts.

  @subject "appointment"

  @behaviour AshCompliance.FactBuilder

  @impl true
  def facts(appointment, opts) do
    [
      {@subject, :transition_to, Keyword.fetch!(opts, :transition_to)},
      {@subject, :patient_weight_recorded, not is_nil(appointment.weight_kg)},
      {@subject, :has_triage_urgency, not is_nil(appointment.triage_urgency)},
      {@subject, :has_notes, present?(appointment.notes)}
    ]
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_notes), do: true
end
