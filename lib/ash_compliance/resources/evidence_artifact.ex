# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.EvidenceArtifact do
  @moduledoc """
  An immutable reference to evidence supporting a control's operation,
  per SP 800-53A assessment methods.

  The artifact itself lives outside the compliance system — this row pins its
  identity: the content hash, media type, collector, the assessment method it
  supports (`examine`, `interview`, or `test`), the chain of custody as an
  append-only list of custody entries, and the retention class.

  Create and read only: evidence is never edited. A corrected artifact is a
  new artifact with a new hash and a new custody entry.
  """

  use AshCompliance.Resource, table: "evidence_artifacts"

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)
    attribute(:control_id, :string, allow_nil?: false, public?: true)
    attribute(:subject_type, :string, public?: true)
    attribute(:subject_id, :string, public?: true)

    attribute(:hash, :string,
      allow_nil?: false,
      public?: true,
      description: "SHA-256 (hex) of the artifact content."
    )

    attribute(:media_type, :string, allow_nil?: false, public?: true)
    attribute(:collector, :string, allow_nil?: false, public?: true)

    attribute(:method, :atom,
      constraints: [one_of: [:examine, :interview, :test]],
      allow_nil?: false,
      public?: true
    )

    attribute(:chain_of_custody, {:array, :map},
      default: [],
      public?: true,
      description: "Ordered custody entries: %{at, actor, action, location}."
    )

    attribute(:retention_class, :string, public?: true)
    attribute(:collected_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([
        :organization_id,
        :control_id,
        :subject_type,
        :subject_id,
        :hash,
        :media_type,
        :collector,
        :method,
        :chain_of_custody,
        :retention_class,
        :collected_at
      ])

      validate attribute_does_not_equal(:hash, "") do
        message("the artifact hash must be non-empty")
      end
    end

    read :get_by_id do
      get_by([:id])
    end

    read :for_control do
      argument(:organization_id, :uuid, allow_nil?: false)
      argument(:control_id, :string, allow_nil?: false)

      filter(expr(organization_id == ^arg(:organization_id) and control_id == ^arg(:control_id)))
    end
  end
end
