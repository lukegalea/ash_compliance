# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.RuleSets.QuestionRules do
  @moduledoc """
  The rule set `AshCompliance.Status.questions/2` is tested against: an
  application that must have its identity and references checked and its
  attached documents signed.

  `identity_checked`, `references_checked` and `signed` are declared
  `missing: :unknown`, so their absence makes the rules probing them
  `:unknown`. `fee_waived` keeps the default `missing: :false`: its absence
  reads as `false`, is reported in the missing facts, and asks nothing.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:submitted, :boolean, description: "Whether the application was submitted")
    fact(:fee_waived, :boolean, description: "Whether the application fee was waived")

    fact(:identity_checked, :boolean,
      missing: :unknown,
      description: "Has the applicant's identity been checked?"
    )

    fact(:references_checked, :boolean,
      missing: :unknown,
      description: "Have the applicant's references been checked?"
    )

    fact(:attached_to, :string, description: "What a document is attached to")

    fact(:signed, :boolean,
      missing: :unknown,
      description: "Has this document been signed?"
    )
  end

  # Unknown while identity_checked is absent; also reads fee_waived, whose
  # absence counts as false.
  rule "a submitted application has its identity checked",
    id: "q.identity_checked",
    severity: :high,
    message: "identity check outstanding",
    evidence: ["identity-record"] do
    when_requires(
      has(:application, :submitted, true),
      has(:application, :fee_waived, false)
    )

    fails_when(neg(:application, :identity_checked, true))
    outcome(:noncompliant, gap: "check the applicant's identity")
  end

  # A second rule probing the same fact; it declares no message.
  rule "a failed identity check blocks the application",
    id: "q.identity_failed",
    severity: :medium do
    when_requires(has(:application, :submitted, true))
    fails_when(has(:application, :identity_checked, false))
    outcome(:noncompliant, gap: "the identity check failed")
  end

  # Names identity_checked too, but is decided before it gets there: a
  # submitted application makes it not applicable.
  rule "a draft application has its identity checked early",
    id: "q.identity_draft",
    severity: :low,
    message: "draft identity check outstanding" do
    when_requires(has(:application, :submitted, false))
    fails_when(neg(:application, :identity_checked, true))
    outcome(:noncompliant, gap: "check identity on the draft")
  end

  # The only rule probing references_checked.
  rule "a submitted application has its references checked",
    id: "q.references_checked",
    severity: :medium,
    message: "reference check outstanding",
    evidence: ["reference-letters"] do
    when_requires(has(:application, :submitted, true))
    fails_when(neg(:application, :references_checked, true))
    outcome(:noncompliant, gap: "check the applicant's references")
  end

  # A variable subject: every document attached to the application.
  rule "every attached document is signed",
    id: "q.documents_signed",
    severity: :medium,
    message: "a document is unsigned",
    evidence: ["signature"] do
    when_requires(has(var(:document), :attached_to, "application"))
    fails_when(neg(var(:document), :signed, true))
    outcome(:noncompliant, gap: "sign every attached document")
  end
end
