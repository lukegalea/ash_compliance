# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Oban) do
  defmodule AshCompliance.Workers.NotifyProjectors do
    @moduledoc """
    The recovery net for missed projector wake-ups.

    The projector engine is normally woken by PubSub broadcasts after every
    committed event. If a broadcast is lost — a node restarts mid-publish, a
    network partition drops it — the events wait for the next drain. This
    worker nudges every configured projector (`config :ash_compliance,
    projectors:`), so a periodic Oban schedule provides an upper bound on
    projection lag independent of PubSub delivery.

    Scheduling (in the host):

        config :ash_compliance, projectors: [MyApp.ComplianceProjector]

        config :my_app, Oban,
          queues: [compliance: 1],
          plugins: [
            {Oban.Plugins.Cron,
             crontab: [{"* * * * *", AshCompliance.Workers.NotifyProjectors}]}
          ]

    The notify is best-effort by design: `AshEvents.Projections.Server.notify/1`
    returns `:ok` when a projector is not running, so the worker never crashes
    on a quiet cluster — it exists to wake things up, not to report on them.
    """

    use Oban.Worker,
      queue: :compliance,
      max_attempts: 5,
      unique: [period: 30]

    @impl Oban.Worker
    def perform(%Oban.Job{args: _args}) do
      :ok =
        AshCompliance.projectors()
        |> Enum.map(&notify(&1.__projector_name__()))
        |> Enum.reduce(:ok, fn
          :ok, :ok -> :ok
          result, _acc -> result
        end)

      :ok
    end

    defp notify(projector_name) do
      AshEvents.Projections.Server.notify(projector_name)
    rescue
      error ->
        {:error, error}
    end
  end
else
  defmodule AshCompliance.Workers.NotifyProjectors do
    @moduledoc """
    Stub compiled when Oban is not a dependency: `perform/1` refuses.

    Scheduling projector wake-ups requires `{:oban, "~> 2.18"}`; without it
    this module exists so a host's projector configuration still compiles.
    """

    def perform(_args), do: {:error, :oban_not_available}
  end
end
