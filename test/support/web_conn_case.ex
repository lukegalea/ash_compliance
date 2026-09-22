# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.WebConnCase do
  @moduledoc """
  Case template for the ruleset editor's LiveView tests.

  The test application (and with it the repo and PubSub the editor's endpoint
  needs) is already started by `test_helper.exs`; this template checks out the
  SQL sandbox and starts the test endpoint, then hands the test a connection.
  Same arrangement as ash_decisions' WebConnCase.
  """

  use ExUnit.CaseTemplate

  alias AshCompliance.TestRepo
  alias Ecto.Adapters.SQL

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint AshCompliance.Web.TestEndpoint
    end
  end

  setup tags do
    pid = SQL.Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> SQL.Sandbox.stop_owner(pid) end)

    start_supervised!(AshCompliance.Web.TestEndpoint)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
