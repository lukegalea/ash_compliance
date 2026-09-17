# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

import Config

config :ash_compliance,
  ecto_repos: [AshCompliance.TestRepo],
  repo: AshCompliance.TestRepo,
  ash_rules_github_repo: "lukegalea/ash_rules"

config :ash_compliance, AshCompliance.TestRepo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5435")),
  database: "ash_compliance_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  queue_target: 1000

# The projector engine reads its adapter surface from application env.
config :ash_events_projections,
  repo: AshCompliance.TestRepo,
  pubsub: AshCompliance.TestPubSub,
  pubsub_topic: "ash_compliance_test:new_event",
  event_log: AshCompliance.Test.Events.Event,
  event_table: "ash_events",
  table_prefix: "ash_projection_",
  projectors: [],
  start_projectors?: false,
  start_probe?: false,
  telemetry_prefix: [:ash_compliance_test]

# Ash loads relationships and calculations in spawned Tasks by default. Those
# are separate processes, so they are not owners of the sandbox connection and
# hit `DBConnection.OwnershipError` intermittently -- the failure is a flake,
# not a consistent error, which is the worst kind. Disabling async in test is
# the standard fix and is what `mix igniter.install ash_postgres` writes.
config :ash, disable_async?: true

config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false

config :logger, level: :warning
