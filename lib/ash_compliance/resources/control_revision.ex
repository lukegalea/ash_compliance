# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.ControlRevision do
  @moduledoc """
  One versioned revision of a `AshCompliance.Resources.Control`: the
  statement text, its parameters, and citations — immutable once created.

  Text changes by appending a revision, so a finding recorded last year can
  always be explained by the control text that was in force when it fired.
  """

  use AshCompliance.Resource, table: "control_revisions"

  attributes do
    uuid_primary_key(:id)

    attribute(:control_id, :uuid, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:statement, :string, public?: true)
    attribute(:params, {:array, :map}, default: [], public?: true)
    attribute(:citations, {:array, :string}, default: [], public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:draft, :active, :withdrawn]],
      default: :draft,
      allow_nil?: false,
      public?: true
    )

    timestamps()
  end

  identities do
    identity(:unique_revision, [:control_id, :version])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:control_id, :version, :statement, :params, :citations, :status])
    end

    update :activate do
      accept([])
      require_atomic?(false)

      validate attribute_equals(:status, :draft) do
        message("only a draft control revision can be activated")
      end

      change(set_attribute(:status, :active))
    end

    update :withdraw do
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :withdrawn))
    end

    read :get_by_id do
      get_by([:id])
    end
  end
end
