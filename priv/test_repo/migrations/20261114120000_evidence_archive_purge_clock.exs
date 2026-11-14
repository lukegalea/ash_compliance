# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.EvidenceArchivePurgeClock do
  @moduledoc """
  The archive's guard trigger counts 400 days from the later of `collected_at` and
  `inserted_at`, so a back-dated `collected_at` cannot make an artifact purgeable early.

  Hand-maintained, like the rest of this directory; the DDL mirrors what `mix
  ash.codegen` generates for the macro in a host.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION evidence_artifact_archive_guard_fn() RETURNS trigger AS $fn$
    BEGIN
      IF TG_OP = 'DELETE'
         AND greatest(OLD.collected_at, OLD.inserted_at) < now() - interval '400 days' THEN
        RETURN OLD;
      END IF;

      RAISE EXCEPTION 'evidence_artifact_archive keeps every artifact for 400 days; % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation',
              HINT = 'Archived evidence is never edited, and is purged only after 400 days.';
    END;
    $fn$ LANGUAGE plpgsql;
    """)
  end

  def down do
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
  end
end
