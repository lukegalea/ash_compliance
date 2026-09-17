# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TestRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_compliance, warn_on_missing_ash_functions?: false

  def installed_extensions, do: ["uuid-ossp", "citext", "ash-functions"]

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end
