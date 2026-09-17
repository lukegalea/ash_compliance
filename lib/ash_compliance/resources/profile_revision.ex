# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.ProfileRevision do
  @moduledoc """
  One immutable revision of a `AshCompliance.Resources.Profile`.

  Tailoring operations are stored as data — a list of typed operation maps in
  declaration order — never as logic:

      %{
        "op" => "refine",
        "rule_id" => "kyc.valid_required",
        "severity" => "high",
        "message" => "jurisdictional policy requires faster remediation"
      }

  Supported operations:

    * `include` — names a control/rule the profile carries (documentary)
    * `exclude` — removes a rule from the effective bundle
    * `parameterize` — sets named parameters (stored; compiler v1 refuses
      rules that consume parameters, since the IR has no parameter binding)
    * `refine` — patches a rule's `severity` and/or `message`
    * `supplement` — adds guidance text against a control (documentary)
    * `replace` / `waive` — these are *overrides* with approval semantics;
      they belong in `AshCompliance.Resources.PolicyOverride`, and a profile
      revision carrying them is refused at compile time

  `content_hash` pins the revision: identical operations produce identical
  hashes.
  """

  use AshCompliance.Resource, table: "profile_revisions"

  alias AshCompliance.Oscal.ProfileOperation

  attributes do
    uuid_primary_key(:id)

    attribute(:profile_id, :uuid, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:source, :string, public?: true)
    attribute(:operations, {:array, :map}, default: [], public?: true)
    attribute(:content_hash, :string, allow_nil?: false, public?: true)

    timestamps()
  end

  identities do
    identity(:unique_revision, [:profile_id, :version])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:profile_id, :version, :source, :operations, :content_hash])
      validate({ProfileOperation.ValidateOperations, []})
    end

    read :get_by_id do
      get_by([:id])
    end

    read :latest_for_profile do
      argument(:profile_id, :uuid, allow_nil?: false)
      prepare(build(sort: [inserted_at: :desc], limit: 1))
      filter(expr(profile_id == ^arg(:profile_id)))
    end
  end
end
