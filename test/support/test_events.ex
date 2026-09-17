# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.Events do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshCompliance.Test.Events.Event)
  end
end

defmodule AshCompliance.Test.Events.Event do
  @moduledoc """
  The test event log. Mirrors the projections test app's shape: the engine's
  schemaless drain selects `practice_id` and `user_id` columns by name, so
  the log carries them (nil is fine — they exist to host metadata extraction
  for the host's own conventions).
  """
  use Ash.Resource,
    domain: AshCompliance.Test.Events,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  event_log do
    advisory_lock_key_generator(AshEvents.Projections.Events.RecordIdAdvisoryLockKeyGenerator)
  end

  attributes do
    attribute(:practice_id, :uuid, public?: true)
    attribute(:user_id, :uuid, public?: true)
  end

  changes do
    change(
      {AshEvents.Projections.Events.Changes.ExtractMetadataFields,
       fields: [
         {:practice_id, cast: :uuid}
       ]},
      on: [:create]
    )

    change(AshEvents.Projections.Events.Changes.NotifyProjectors, on: [:create])
  end

  postgres do
    table("ash_events")
    repo(AshCompliance.TestRepo)
  end
end
