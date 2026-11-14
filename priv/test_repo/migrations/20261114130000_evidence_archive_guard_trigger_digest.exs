# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.EvidenceArchiveGuardTriggerDigest do
  @moduledoc """
  The archive's guard trigger statement names the digest of the function it calls, so a
  change to the function recreates both: the trigger is dropped before the function and
  created after it.

  Hand-maintained, like the rest of this directory; the DDL mirrors what `mix
  ash.codegen` generates for the macro in a host.
  """

  use Ecto.Migration

  def up do
    execute("""
    -- evidence_artifact_archive_guard_fn: 030d22eeccc6285e
    CREATE OR REPLACE TRIGGER evidence_artifact_archive_guard
      BEFORE UPDATE OR DELETE ON evidence_artifact_archive
      FOR EACH ROW EXECUTE FUNCTION evidence_artifact_archive_guard_fn();
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE TRIGGER evidence_artifact_archive_guard
      BEFORE UPDATE OR DELETE ON evidence_artifact_archive
      FOR EACH ROW EXECUTE FUNCTION evidence_artifact_archive_guard_fn();
    """)
  end
end
