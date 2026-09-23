# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.FactBuilder do
  @moduledoc """
  The fact-builder contract: how a host record becomes the triples a rule
  bundle probes.

  `AshCompliance.status_for/2` evaluates the organization's active bundle
  against facts. The bundle speaks policy (`has(:appointment,
  :patient_weight_recorded, true)`), not storage — something must translate
  the record into those probes, and that something is host code, because only
  the host knows how its records are stored and loaded. This behaviour is the
  contract; the clinic-demo guard's `facts/1` is the reference shape.

  ## The contract

  A fact builder is any of:

    * a module implementing this behaviour — `facts(record, opts)` returns
      the triples;
    * a `{module, function}` pair — called as `module.function(record, opts)`;
    * a capture — `fn record -> ... end` or `fn record, opts -> ... end`.

  When no builder is given, `status_for/2` checks whether the record's own
  module implements the behaviour and calls it; that keeps the contract next
  to the resource when the host prefers it there.

  The callback returns a list of `{subject, predicate, value}` triples, and:

    1. **The subject is a string, deliberately not an atom.** A bundle's
       predicates travel through the compliance control plane as JSON, and
       subject terms are opaque there: the DSL's `has(:appointment, ...)`
       arrives back as `"appointment"`. Facts are emitted under the
       post-compile spelling so the probes always meet the rules.
    2. **Predicates are atoms declared in the active bundle's fact schema.**
       A fact outside the schema fails the evaluation with an error naming
       the fix (declare the fact or drop it) — the engine refuses to guess.
    3. **Facts are precomputed policy, not raw storage.** Emit
       `patient_weight_recorded: true`, not a weight in kilograms: the rule
       vocabulary stays about policy, and thresholds stay in the builder, not
       duplicated into rules.
    4. **Omission is meaningful.** Do not emit facts that are not true. A
       schema entry declared `missing: :unknown` that no triple supplies
       turns its rule `:unknown` — never compliant, never a violation.
    5. **Context beyond the record arrives in `opts`.** `status_for/2` passes
       its own options through, minus the framework-reserved keys
       (`:organization`, `:bundle`, `:facts`, `:fact_builder`): the guard's
       `transition_to` is exactly this, and a status surface answering "is
       this appointment compliant *to check in*?" passes the same key.

  ## Example

  The guard-shaped builder, as a host would write it:

      defmodule MyApp.AppointmentFacts do
        @behaviour AshCompliance.FactBuilder

        @subject "appointment"

        @impl true
        def facts(appointment, opts) do
          [
            {@subject, :transition_to, Keyword.fetch!(opts, :transition_to)},
            {@subject, :patient_weight_recorded, not is_nil(appointment.weight_kg)},
            {@subject, :has_triage_urgency, not is_nil(appointment.triage_urgency)},
            {@subject, :has_notes, not blank?(appointment.notes)}
          ]
        end
      end

  and the status query:

      AshCompliance.status_for(appointment,
        organization: {MyApp.Compliance, :organization_id, []},
        fact_builder: MyApp.AppointmentFacts,
        transition_to: :checked_in
      )
  """

  @callback facts(record :: term(), opts :: keyword()) :: [AshRules.Facts.triple()]
end
