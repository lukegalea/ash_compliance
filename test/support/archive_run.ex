# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.ArchiveRun do
  @moduledoc """
  A run ledger with the shape `AshCompliance.Ownership.Retention` records into: a
  `:record` create accepting the step's attributes. In memory; the tests read it back.
  """

  use Ash.Resource,
    domain: AshCompliance.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(false)
  end

  actions do
    defaults([:read])

    create :record do
      primary?(true)
      accept([:store, :kind, :status, :row_count, :digest, :cutoff, :reason])
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:store, :atom, allow_nil?: false, public?: true)
    attribute(:kind, :atom, allow_nil?: false, public?: true)
    attribute(:status, :atom, allow_nil?: false, public?: true)
    attribute(:row_count, :integer, allow_nil?: false, public?: true)
    attribute(:digest, :string, public?: true)
    attribute(:cutoff, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:reason, :string, public?: true)
  end
end
