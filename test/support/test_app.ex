# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.TestApp do
  @moduledoc """
  Test-only application hosting the repo, PubSub and Oban (in manual testing
  mode) so resource actions and worker tests run against the sandbox.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AshCompliance.TestRepo,
      {Phoenix.PubSub, name: AshCompliance.TestPubSub},
      {Oban, testing: :manual, queues: [compliance: 1], repo: AshCompliance.TestRepo}
    ]

    opts = [strategy: :one_for_one, name: AshCompliance.TestApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
