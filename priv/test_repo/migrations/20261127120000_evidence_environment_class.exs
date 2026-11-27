# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.EvidenceEnvironmentClass do
  @moduledoc """
  `environment_class` on `evidence_artifacts` and on the evidence archive: the class of the
  environment the evidence was collected in. Nullable, so existing rows keep their meaning
  (nothing said about the environment).

  Hand-maintained, like the rest of this directory; the DDL mirrors a nullable atom
  attribute on the hot table and a nullable string on the archive.
  """

  use Ecto.Migration

  def up do
    alter table(:ash_compliance_evidence_artifacts) do
      add :environment_class, :text
    end

    alter table(:evidence_artifact_archive) do
      add :environment_class, :text
    end
  end

  def down do
    alter table(:evidence_artifact_archive) do
      remove :environment_class
    end

    alter table(:ash_compliance_evidence_artifacts) do
      remove :environment_class
    end
  end
end
