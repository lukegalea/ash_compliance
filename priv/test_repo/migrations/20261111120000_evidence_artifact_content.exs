# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.EvidenceArtifactContent do
  @moduledoc """
  `content` on `evidence_artifacts`: the bytes the hash pins, when the writer kept them.
  Nullable so existing rows keep their meaning (a hash with no stored bytes).

  Hand-maintained, like the rest of this directory; the DDL mirrors a nullable binary
  attribute.
  """

  use Ecto.Migration

  def up do
    alter table(:ash_compliance_evidence_artifacts) do
      add :content, :binary
    end
  end

  def down do
    alter table(:ash_compliance_evidence_artifacts) do
      remove :content
    end
  end
end
