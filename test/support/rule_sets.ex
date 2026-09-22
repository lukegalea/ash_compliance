# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.RuleSets.GlobalBaseline do
  @moduledoc """
  The global baseline rule set: two rules, one of them filed under the KYC
  control gap, one under the review gap. `has_valid_kyc` is declared
  `missing: :unknown` — the invariant "missing evidence is never compliant"
  hangs off it.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:status, :atom, one_of: [:active, :suspended])
    fact(:jurisdiction, :atom)
    fact(:has_valid_kyc, :boolean, missing: :unknown)
    fact(:reviewed, :boolean, missing: :no_fact)
    fact(:owner, :atom)
    fact(:balance, :integer)
  end

  rule "active regulated customer requires valid KYC",
    id: "kyc.valid_required",
    severity: :medium,
    message: "customer %{customer} requires valid KYC" do
    when_requires(
      has(:customer, :status, :active),
      has(:customer, :jurisdiction, :regulated)
    )

    fails_when(neg(:customer, :has_valid_kyc, true))
    outcome(:noncompliant, gap: "kyc.valid_required")
  end

  rule "active regulated customer requires a recorded review",
    id: "kyc.review_required",
    severity: :high do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :reviewed, true))
    outcome(:noncompliant, gap: "kyc.review")
  end
end

defmodule AshCompliance.Test.RuleSets.TenantStrengthening do
  @moduledoc false

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:status, :atom, one_of: [:active, :suspended])
    fact(:jurisdiction, :atom)
    fact(:has_valid_kyc, :boolean, missing: :unknown)
    fact(:reviewed, :boolean, missing: :no_fact)
    fact(:owner, :atom)
    fact(:balance, :integer)
  end

  rule "suspended customers carry no balance (tenant strengthening)",
    id: "acct.balance_frozen",
    severity: :low,
    message: "account %{account} holds a balance while suspended" do
    when_requires(
      has(:customer, :status, :suspended),
      has(var(:account), :owner, :customer)
    )

    fails_when(neg(var(:account), :balance, 0))
    outcome(:noncompliant, gap: "kyc.balance")
  end
end

defmodule AshCompliance.Test.RuleSets.TenantSupplement do
  @moduledoc false

  # A supplement-layer rule that an approved replacement may displace.

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:status, :atom, one_of: [:active, :suspended])
    fact(:jurisdiction, :atom)
    fact(:has_valid_kyc, :boolean, missing: :unknown)
    fact(:reviewed, :boolean, missing: :no_fact)
    fact(:owner, :atom)
    fact(:balance, :integer)
  end

  rule "supplement: customer welcome review",
    id: "kyc.welcome_review",
    severity: :low,
    message: "welcome review missing" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :reviewed, true))
    outcome(:noncompliant, gap: "kyc.welcome")
  end
end

defmodule AshCompliance.Test.RuleSets.GlobalNonWaivable do
  @moduledoc false

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:status, :atom, one_of: [:active, :suspended])
    fact(:jurisdiction, :atom)
    fact(:has_valid_kyc, :boolean, missing: :unknown)
    fact(:reviewed, :boolean, missing: :no_fact)
    fact(:owner, :atom)
    fact(:balance, :integer)
  end

  rule "all customers must have a jurisdiction",
    id: "kyc.jurisdiction_required",
    severity: :critical do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :jurisdiction, :regulated))
    outcome(:noncompliant, gap: "kyc.jurisdiction")
  end
end

defmodule AshCompliance.Test.RuleSets.EditorRoundTrip do
  @moduledoc false

  # Exercises everything the ruleset editor edits, so the encode → decode
  # round-trip test proves the editing model is lossless: facts of several
  # types with one_of and all three missing semantics, rules with variable
  # and ground subjects, has/neg triples, a gap text, and a non-default
  # combining algorithm.

  use AshRules

  combining(:permit_overrides)

  fact_schema do
    fact(:status, :atom, one_of: [:active, :suspended], description: "lifecycle state")
    fact(:jurisdiction, :atom)
    fact(:has_valid_kyc, :boolean, missing: :unknown)
    fact(:reviewed, :boolean, missing: :no_fact)
    fact(:notes, :string)
    fact(:balance, :integer)
    fact(:ratio, :float)
    fact(:opened_on, :date)
    fact(:owner, :atom)
  end

  rule "active regulated customer requires valid KYC",
    id: "kyc.valid_required",
    severity: :medium,
    message: "customer %{customer} requires valid KYC",
    controls: ["kyc-1"],
    evidence: ["kyc-evidence"] do
    when_requires(
      has(:customer, :status, :active),
      has(:customer, :jurisdiction, :regulated)
    )

    fails_when(neg(:customer, :has_valid_kyc, true))
    outcome(:noncompliant, gap: "kyc.valid_required")
  end

  rule "suspended customers carry no balance",
    id: "acct.balance_frozen",
    severity: :high,
    message: "account %{account} holds a balance while suspended" do
    when_requires(
      has(:customer, :status, :suspended),
      has(var(:account), :owner, :customer)
    )

    fails_when(neg(var(:account), :balance, 0))
    outcome(:noncompliant, gap: "acct.balance")
  end

  rule "active customers carry a note and an opening date",
    id: "kyc.notes_and_dates",
    severity: :low,
    remediation_ref: "kyc-remediation-3" do
    when_requires(
      has(:customer, :status, :active),
      has(:customer, :notes, " reviewed "),
      has(:customer, :ratio, 1.5),
      has(:customer, :opened_on, ~D[2020-01-01])
    )

    fails_when(neg(:customer, :reviewed, true))
    outcome(:noncompliant, gap: "kyc.notes")
  end
end

defmodule AshCompliance.Test.Support do
  @moduledoc false

  # Fixture helpers for the control-plane specs.

  def bundle_json(module) do
    AshRules.Ir.encode!(module.__bundle__())
  end

  def rule_set_revision(attrs) do
    defaults = [
      name: "ruleset-" <> AshCompliance.Support.unique(),
      revision: "1",
      layer: :global_mandatory,
      combining: :deny_overrides,
      rules_json: bundle_json(AshCompliance.Test.RuleSets.GlobalBaseline),
      content_hash: AshCompliance.Test.RuleSets.GlobalBaseline.__bundle__().content_hash
    ]

    AshCompliance.Domain.draft_rule_set_revision!(Keyword.merge(defaults, attrs),
      authorize?: false
    )
  end

  def unique, do: AshCompliance.Support.unique()
end

defmodule AshCompliance.Support do
  @moduledoc false

  def unique do
    :erlang.unique_integer([:positive, :monotonic]) |> Integer.to_string()
  end
end

defmodule AshCompliance.Test.Projector do
  @moduledoc false

  use AshCompliance.Projector,
    name: "compliance_findings_v1",
    event_log: AshCompliance.Test.Events.Event,
    projection_resource: AshCompliance.Resources.Finding,
    bundle: {AshCompliance.Test.Projector, :active_bundle, []}

  grain(fn event ->
    metadata = event.metadata || %{}

    %{
      organization_id: metadata["organization_id"],
      control_id: metadata["control_id"],
      subject_type: metadata["subject_type"],
      subject_id: metadata["subject_id"]
    }
  end)

  project_all([:kyc_reviewed])

  def active_bundle(event) do
    organization_id = event.metadata["organization_id"]

    case AshCompliance.Domain.active_policy_bundle(organization_id, authorize?: false) do
      {:ok, nil} ->
        {:error, :no_active_bundle}

      {:ok, bundle} ->
        AshRules.Ir.decode(bundle.rules_json)

      {:error, error} ->
        {:error, error}
    end
  end
end
