# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.ProcessResources do
  @moduledoc """
  The operator-process tables: approval attempts and the access review campaign,
  its rows and its decisions.

  Hand-maintained, like the rest of this directory. The decision and attempt
  tables also get a trigger that refuses UPDATE and DELETE. The resources expose
  no such action, and a host that wants the same guarantee at the database
  adds the same trigger in its own migration:

      CREATE FUNCTION <prefix>refuse_change() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'append-only: % on % is not allowed', TG_OP, TG_TABLE_NAME;
      END;
      $$ LANGUAGE plpgsql;
  """

  use Ecto.Migration

  def up do
    create table(:ash_compliance_approval_attempts, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:organization_id, :uuid, null: false)
      add(:process_key, :text, null: false)
      add(:subject_id, :text, null: false)
      add(:requester_id, :text)
      add(:approver_id, :text)
      add(:delegation_chain, {:array, :text}, null: false, default: [])
      add(:delegation_recorded?, :boolean, null: false, default: true)
      add(:outcome, :text, null: false)
      add(:reason, :text, null: false)
      add(:decision_hash, :text, null: false)
      timestamps(updated_at: false)
    end

    create(
      index(:ash_compliance_approval_attempts, [:organization_id, :process_key, :subject_id])
    )

    create table(:ash_compliance_access_review_campaigns, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:organization_id, :uuid, null: false)
      add(:name, :text, null: false)
      add(:period, :text, null: false)
      add(:status, :text, null: false, default: "incomplete")
      add(:source_ids, {:array, :text}, null: false, default: [])
      add(:source_results, :map, null: false, default: %{})
      add(:opened_by, :text, null: false)
      add(:opened_at, :utc_datetime_usec, null: false)
      add(:closed_by, :text)
      add(:closed_at, :utc_datetime_usec)
      add(:close_summary, :map)
      timestamps(updated_at: false)
    end

    create(index(:ash_compliance_access_review_campaigns, [:organization_id]))

    create table(:ash_compliance_access_review_rows, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:organization_id, :uuid, null: false)

      add(
        :campaign_id,
        references(:ash_compliance_access_review_campaigns, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:person_key, :text, null: false)
      add(:sources, {:array, :text}, null: false, default: [])
      add(:entitlements, :map, null: false, default: %{})
      add(:entitlement_digest, :text, null: false)
      timestamps(updated_at: false)
    end

    create(
      unique_index(:ash_compliance_access_review_rows, [:campaign_id, :person_key],
        name: "ash_compliance_access_review_rows_one_row_per_person_index"
      )
    )

    create table(:ash_compliance_access_review_decisions, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:organization_id, :uuid, null: false)

      add(
        :campaign_id,
        references(:ash_compliance_access_review_campaigns, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :row_id,
        references(:ash_compliance_access_review_rows, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:reviewer_id, :text, null: false)
      add(:decision, :text, null: false)
      add(:reason, :text)
      add(:delegation_chain, {:array, :text}, null: false, default: [])
      add(:entitlement_digest, :text, null: false)
      add(:decided_at, :utc_datetime_usec, null: false)
      add(:record_hash, :text, null: false)
      timestamps(updated_at: false)
    end

    create(index(:ash_compliance_access_review_decisions, [:campaign_id]))
    create(index(:ash_compliance_access_review_decisions, [:row_id]))

    execute("""
    CREATE FUNCTION ash_compliance_refuse_change() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'append-only: % on % is not allowed', TG_OP, TG_TABLE_NAME;
    END;
    $$ LANGUAGE plpgsql
    """)

    for table <- ~w(ash_compliance_access_review_decisions ash_compliance_approval_attempts) do
      execute("""
      CREATE TRIGGER #{table}_append_only
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION ash_compliance_refuse_change()
      """)
    end
  end

  def down do
    for table <- ~w(ash_compliance_access_review_decisions ash_compliance_approval_attempts) do
      execute("DROP TRIGGER IF EXISTS #{table}_append_only ON #{table}")
    end

    execute("DROP FUNCTION IF EXISTS ash_compliance_refuse_change()")
    drop(table(:ash_compliance_access_review_decisions))
    drop(table(:ash_compliance_access_review_rows))
    drop(table(:ash_compliance_access_review_campaigns))
    drop(table(:ash_compliance_approval_attempts))
  end
end
