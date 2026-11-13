# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.EvidenceArtifactArchive do
  @moduledoc """
  The test app's evidence archive (`AshCompliance.Test.ArchivedEvidence`, built with
  `use AshCompliance.Resources, {:evidence_archive, opts}`): the hot table's columns plus
  `archived_at`, the control index, and the guard trigger the macro declares.

  Hand-maintained, like the rest of this directory; the DDL mirrors what `mix
  ash.codegen` generates for the macro in a host.
  """

  use Ecto.Migration

  def up do
    create table(:evidence_artifact_archive, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :organization_id, :uuid, null: false
      add :control_id, :text, null: false
      add :subject_type, :text
      add :subject_id, :text
      add :hash, :text, null: false
      add :content, :binary
      add :media_type, :text, null: false
      add :collector, :text, null: false
      add :method, :text, null: false
      add :chain_of_custody, {:array, :map}
      add :retention_class, :text
      add :collected_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :archived_at, :utc_datetime_usec, null: false
    end

    create index(:evidence_artifact_archive, [:organization_id, :control_id, :collected_at],
             name: "evidence_artifact_archive_control_index"
           )

    execute("""
    CREATE OR REPLACE FUNCTION evidence_artifact_archive_guard_fn() RETURNS trigger AS $fn$
    BEGIN
      IF TG_OP = 'DELETE' AND OLD.collected_at < now() - interval '400 days' THEN
        RETURN OLD;
      END IF;

      RAISE EXCEPTION 'evidence_artifact_archive keeps every artifact for 400 days; % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation',
              HINT = 'Archived evidence is never edited, and is purged only after 400 days.';
    END;
    $fn$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE TRIGGER evidence_artifact_archive_guard
      BEFORE UPDATE OR DELETE ON evidence_artifact_archive
      FOR EACH ROW EXECUTE FUNCTION evidence_artifact_archive_guard_fn();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS evidence_artifact_archive_guard ON evidence_artifact_archive;")
    execute("DROP FUNCTION IF EXISTS evidence_artifact_archive_guard_fn();")
    drop table(:evidence_artifact_archive)
  end
end
