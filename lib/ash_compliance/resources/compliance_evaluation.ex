# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.ComplianceEvaluation do
  @moduledoc """
  The append-only record of one evaluation: what the engine decided and why.

  Deliberately **not** a projection. The finding is the current state; the
  evaluation is history — the bundle revision and hash that were in force,
  the hash of the fact snapshot that was evaluated, the outcome, the facts
  that were missing, the evaluator version, the correlation id and the source
  event. An auditor reconstructs any past decision from evaluations alone.

  Create-only: evaluations are never updated, corrected or deleted. A wrong
  evaluation is superseded by the next evaluation, not rewritten.
  """

  use AshCompliance.Resource, table: "compliance_evaluations"

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)
    attribute(:control_id, :string, public?: true)
    attribute(:subject_type, :string, public?: true)
    attribute(:subject_id, :string, public?: true)

    attribute(:bundle_hash, :string, allow_nil?: false, public?: true)
    attribute(:bundle_revision, :string, public?: true)
    attribute(:evaluator, :string, allow_nil?: false, public?: true)
    attribute(:compiler_version, :string, public?: true)

    attribute(:outcome, :atom,
      constraints: [one_of: [:compliant, :noncompliant, :not_applicable, :unknown, :error]],
      allow_nil?: false,
      public?: true
    )

    attribute(:fact_snapshot_hash, :string, allow_nil?: false, public?: true)
    attribute(:missing_facts, {:array, :string}, default: [], public?: true)
    attribute(:rule_ids, {:array, :string}, default: [], public?: true)

    attribute(:correlation_id, :string, public?: true)
    attribute(:source_event_id, :string, public?: true)
    attribute(:evaluated_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end

  actions do
    defaults([:read])

    create :record do
      primary?(true)

      accept([
        :organization_id,
        :control_id,
        :subject_type,
        :subject_id,
        :bundle_hash,
        :bundle_revision,
        :evaluator,
        :compiler_version,
        :outcome,
        :fact_snapshot_hash,
        :missing_facts,
        :rule_ids,
        :correlation_id,
        :source_event_id,
        :evaluated_at
      ])
    end

    read :get_by_id do
      get_by([:id])
    end

    read :for_subject do
      argument(:organization_id, :uuid, allow_nil?: false)
      argument(:subject_type, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      prepare(build(sort: [inserted_at: :desc]))

      filter(
        expr(
          organization_id == ^arg(:organization_id) and
            subject_type == ^arg(:subject_type) and
            subject_id == ^arg(:subject_id)
        )
      )
    end
  end
end
