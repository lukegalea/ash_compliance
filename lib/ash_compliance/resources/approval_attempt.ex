# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.ApprovalAttempt do
  @moduledoc """
  One attempt to approve something, permitted or refused.

  `AshCompliance.Processes.Approval` writes a row for every attempt after asking
  the separation-of-duties decision, so a self-approval is not merely stopped, it
  is on record with who tried, for whom, through which delegation chain, and the
  hash of the decision document that answered.

  Create and read only. An attempt is never edited or removed; a hardening
  trigger for the table is described in the ownership and processes topic.

  `:record` takes the people and the delegation chain and asks the decision
  itself (`Changes.Decide`): `outcome`, `reason` and `decision_hash` are not
  inputs, so a row cannot claim a permit the decision did not give.

  ## Authorization

  Reads are open; the host decides who sees them. No actor may write an
  attempt: the approver on a row is whoever the caller names, so a write from a
  request would let anyone put an approval on record in someone else's name.
  Attempts are written by `AshCompliance.Processes.Approval` and
  `AshCompliance.Processes.Gate`, which run `authorize?: false` as trusted
  machinery.
  """

  use AshCompliance.Resource,
    table: "approval_attempts",
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key(:id)

    attribute(:organization_id, :uuid, allow_nil?: false, public?: true)

    attribute(:process_key, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1]
    )

    attribute(:subject_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1],
      description: "The process instance, task or campaign row the approval was for."
    )

    attribute(:requester_id, :string,
      public?: true,
      description: "As supplied; nil or blank when the caller did not know."
    )

    attribute(:approver_id, :string, public?: true)

    attribute(:delegation_chain, {:array, :string},
      default: [],
      public?: true,
      description: "The people the approver was acting for. Empty when not delegated."
    )

    attribute(:delegation_recorded?, :boolean,
      allow_nil?: false,
      default: true,
      public?: true,
      description: "False when the caller could not say whether a delegation was in play."
    )

    attribute(:outcome, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:permitted, :refused]]
    )

    attribute(:reason, :string, allow_nil?: false, public?: true)

    attribute(:decision_hash, :string,
      allow_nil?: false,
      public?: true,
      description: "SHA-256 of the decision document that answered."
    )

    create_timestamp(:inserted_at)
  end

  actions do
    defaults([:read])

    create :record do
      primary?(true)

      accept([
        :organization_id,
        :process_key,
        :subject_id,
        :requester_id,
        :approver_id,
        :delegation_chain,
        :delegation_recorded?
      ])

      change({AshCompliance.Resources.ApprovalAttempt.Changes.Decide, []})
    end

    read :for_subject do
      argument(:organization_id, :uuid, allow_nil?: false)
      argument(:process_key, :string, allow_nil?: false)
      argument(:subject_id, :string, allow_nil?: false)

      filter(
        expr(
          organization_id == ^arg(:organization_id) and process_key == ^arg(:process_key) and
            subject_id == ^arg(:subject_id)
        )
      )
    end

    read :for_organization do
      argument(:organization_id, :uuid, allow_nil?: false)
      filter(expr(organization_id == ^arg(:organization_id)))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(never())
    end
  end
end
