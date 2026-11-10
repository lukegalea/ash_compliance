# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.PolicyOverrideRequestedBy do
  @moduledoc """
  `requested_by` on `policy_overrides`: who asked for the override. Nullable so
  existing rows keep their meaning; rows without it never silence a criterion.

  Hand-maintained, like the rest of this directory (see
  `DeclaredSchemeColumns`); the DDL mirrors a nullable text attribute.
  """

  use Ecto.Migration

  def up do
    alter table(:ash_compliance_policy_overrides) do
      add :requested_by, :text
    end
  end

  def down do
    alter table(:ash_compliance_policy_overrides) do
      remove :requested_by
    end
  end
end
