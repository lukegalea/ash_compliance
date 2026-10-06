# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TestRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_compliance, warn_on_missing_ash_functions?: false

  # `btree_gist` is the Phase 0 (PostgreSQL 18) temporal-readiness floor: the
  # later temporal surface (waiver `policy_override` non-overlap, the revision
  # cluster's in-force semantics) builds exclusion constraints over range
  # types, and every non-GiST-native column in such a constraint needs this
  # extension. The migration generator diffs this list against the extensions
  # snapshot and emits the CREATE EXTENSION migration when that surface lands.
  def installed_extensions, do: ["uuid-ossp", "citext", "ash-functions", "btree_gist"]

  # Phase 0 pins the declared floor to the server the programme develops
  # against (PostgreSQL 18; the shared ash_enterprise devenv provides 18.4).
  # This is ash_postgres' feature-gating declaration, not a runtime server
  # check -- the generated migrations use PG18 features (native uuidv7()),
  # which is why CI's service image must be pg18 too.
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
