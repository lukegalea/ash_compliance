# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.TaskSource do
  @moduledoc """
  Where the open human tasks of a host's processes are read from.

  The process engine keeps its tasks in the host's database. This behaviour is
  the one question `AshCompliance.Processes.Overdue` asks of it: what is open
  right now, and when was each task due?

  A task is a map with

    * `:id` - a non-blank string identifying the task
    * `:process_key` - the template process key, such as
      `"compliance.access_request"`
    * `:due_at` - a `DateTime`

  A source that cannot answer returns `{:error, reason}`. That is reported as a
  finding, never as "nothing is overdue".
  """

  @type task :: %{id: String.t(), process_key: String.t(), due_at: DateTime.t()}

  @callback open_tasks(organization_id :: String.t(), opts :: keyword()) ::
              {:ok, [task()]} | {:error, term()}
end
