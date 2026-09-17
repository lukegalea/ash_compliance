# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.Finding do
  @moduledoc """
  The current compliance state of one subject against one control.

  This is a **projection**: the `ash_events_projections` engine folds
  compliance events into it, keyed on the finding grain
  `[organization_id, control_id, subject_type, subject_id]`. It is the
  "now" — the answer to "is this subject compliant today?"

  It is deliberately distinct from `AshCompliance.Resources.ComplianceEvaluation`,
  which is the append-only record of what the engine decided and why. The
  projection answers queries; the evaluation answers auditors.

  `status` carries the outcome for the control (the bundle's combining
  algorithm applied over the rules filed under its gap); `explanation` is the
  winning finding message or a summary of what is missing; `first_seen_at`,
  `last_seen_at` and `resolved_at` are derived from event timestamps, so a
  replay of the same events reproduces them exactly.
  """

  use Ash.Resource,
    domain: AshCompliance.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  @repo Application.compile_env(:ash_compliance, :repo, AshCompliance.TestRepo)

  projection_resource do
    grain_fields([:organization_id, :control_id, :subject_type, :subject_id])
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)
    attribute(:control_id, :string, allow_nil?: false, public?: true)
    attribute(:subject_type, :string, allow_nil?: false, public?: true)
    attribute(:subject_id, :string, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:compliant, :noncompliant, :unknown, :error]],
      allow_nil?: false,
      default: :unknown,
      public?: true
    )

    attribute(:severity, :atom,
      constraints: [one_of: [:low, :medium, :high, :critical]],
      public?: true
    )

    attribute(:gap, :string, public?: true)

    attribute(:breach_count, :integer, allow_nil?: false, default: 0, public?: true)

    attribute(:first_seen_at, :utc_datetime_usec, public?: true)
    attribute(:last_seen_at, :utc_datetime_usec, public?: true)
    attribute(:resolved_at, :utc_datetime_usec, public?: true)

    attribute(:explanation, :string, public?: true)
    attribute(:bundle_hash, :string, public?: true)

    attribute(:rule_ids, {:array, :string}, default: [], public?: true)

    timestamps()
  end

  postgres do
    table(
      Application.compile_env(:ash_compliance, :table_prefix, "ash_compliance_") <> "findings"
    )

    repo(@repo)
  end

  actions do
    defaults([:read])

    read :noncompliant_for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id) and status == :noncompliant))
    end

    read :for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end

    read :get_by_id do
      get_by([:id])
    end
  end
end
