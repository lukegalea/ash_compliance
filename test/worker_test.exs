# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Workers.NotifyProjectorsTest do
  @moduledoc """
  The drain-nudge worker: schedules projector wake-ups as a recovery net for
  missed PubSub broadcasts. Oban runs in manual testing mode.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.Workers.NotifyProjectors

  test "perform nudges the configured projectors and succeeds even when none run" do
    # No projector servers are started in the test environment: notify/1 is
    # best-effort (:ok when the projector is not running), so the worker must
    # still report success — it exists to wake things up, not to report.
    job = %Oban.Job{args: %{}}

    assert :ok = NotifyProjectors.perform(job)
  end

  test "the worker is enqueueable through Oban" do
    {:ok, job} = Oban.insert(NotifyProjectors.new(%{}))

    assert job.id
    assert job.queue == "compliance"
  end
end
