# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# The database is created and migrated here, once per test run, so a fresh
# clone needs no setup task. Migrations run outside the sandbox (:auto), and
# the pool is switched to manual ownership afterwards.

{:ok, _} = Application.ensure_all_started(:ecto_sql)

unless System.get_env("SKIP_DB") do
  # The `mix test` alias creates and migrates the database before the test
  # application boots (Oban needs oban_jobs at boot). This is the idempotent
  # re-check for direct `mix test path/to/test.exs` runs.
  Ecto.Adapters.SQL.Sandbox.mode(AshCompliance.TestRepo, :auto)

  case AshCompliance.TestRepo.__adapter__().storage_up(AshCompliance.TestRepo.config()) do
    :ok -> :ok
    {:error, :already_up} -> :ok
  end

  Ecto.Migrator.run(AshCompliance.TestRepo, "priv/test_repo/migrations", :up, all: true)

  Ecto.Adapters.SQL.Sandbox.mode(AshCompliance.TestRepo, :manual)
end

ExUnit.start()
