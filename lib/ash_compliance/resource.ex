# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resource do
  @moduledoc false

  # Shared resource scaffolding: every AshCompliance resource resolves its
  # Ecto repo and table name at compile time from application env, so hosts
  # wire their own repo without forking the resources:
  #
  #     config :ash_compliance, repo: MyApp.Repo, table_prefix: "ash_compliance_"
  #
  # Same pattern as AshEvents.Projections.InternalResource.
  #
  # `authorizers:` is passed through. Most resources take none (the host owns
  # authorization); the two whose rows stand as an approval on record,
  # `ApprovalAttempt` and `PolicyOverride`, take the policy authorizer and
  # refuse every write from an actor.

  defmacro __using__(opts) do
    table_suffix = Keyword.fetch!(opts, :table)

    quote do
      @repo Application.compile_env(:ash_compliance, :repo, AshCompliance.TestRepo)

      @table Application.compile_env(:ash_compliance, :table_prefix, "ash_compliance_") <>
               unquote(table_suffix)

      use Ash.Resource,
        domain: AshCompliance.Domain,
        data_layer: AshPostgres.DataLayer,
        authorizers: unquote(Keyword.get(opts, :authorizers, []))

      postgres do
        table(@table)
        repo(@repo)
      end
    end
  end
end
