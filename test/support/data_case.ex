# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.DataCase do
  @moduledoc """
  Sandbox + Ash helpers for compliance tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import AshCompliance.DataCase

      alias AshCompliance.TestRepo
    end
  end

  setup tags do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(AshCompliance.TestRepo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
