# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Testing do
  @moduledoc """
  Deterministic, synchronous draining for hosts that test their projector.

  `AshEvents.Projections.Server` drains asynchronously against its own
  connection, which keeps it outside a test's sandbox transaction. This
  module folds a list of event rows through the projector using exactly the
  same public machinery the Server uses — `__grain__/0`, `upsert_grain`,
  `handle_event/2`, `apply_projection_ops` — synchronously, inside the
  caller's transaction.

  Replay determinism testing then becomes: drain the same events into fresh
  tables twice, compare everything.
  """

  @doc """
  Folds events (in the order given) through the projector.

  Events are the normalized rows the projector engine produces; create them
  with `AshCompliance.Testing.event/2` in tests, or read them from the log.
  """
  @spec drain_sync(module(), [map()]) :: :ok
  def drain_sync(projector, events) do
    Enum.each(events, fn event ->
      grain_key = projector.__grain__().(event)

      if grain_key do
        row =
          if projector.needs_current_state?(event) do
            Ash.create!(projector.__projection_resource__(), grain_key,
              action: :upsert_grain,
              authorize?: false
            )
          end

        case projector.handle_event(event, row) do
          {:ok, ops} when ops != [] ->
            Ash.update!(row, %{ops: ops}, action: :apply_projection_ops, authorize?: false)

          _ ->
            :ok
        end
      end
    end)

    :ok
  end

  @doc """
  Builds a normalized event row like the ones the projector engine hands to
  handlers. The metadata carries the compliance payload: grain identity,
  correlation id, and the fact triples.
  """
  @spec event(keyword()) :: map()
  def event(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    %{
      id: Keyword.get(opts, :id, :erlang.unique_integer([:positive])),
      practice_id: nil,
      user_id: nil,
      occurred_at:
        Keyword.get(
          opts,
          :occurred_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        ),
      metadata: metadata,
      resource: Keyword.get(opts, :resource, :customer),
      action: Keyword.fetch!(opts, :action),
      action_type: Keyword.get(opts, :action_type, :update)
    }
  end
end
