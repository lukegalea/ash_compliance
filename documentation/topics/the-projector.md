<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# The projector

## The shape

```elixir
defmodule MyApp.ComplianceProjector do
  use AshCompliance.Projector,
    name: "compliance_findings_v1",
    event_log: MyApp.Events.Event,
    projection_resource: AshCompliance.Resources.Finding,
    bundle: {__MODULE__, :active_bundle, []}

  grain fn event ->
    metadata = event.metadata || %{}

    %{
      organization_id: metadata["organization_id"],
      control_id: metadata["control_id"],
      subject_type: metadata["subject_type"],
      subject_id: metadata["subject_id"]
    }
  end

  project_all [:kyc_reviewed]
end
```

The grain is the finding's identity — `[organization_id, control_id,
subject_type, subject_id]` — and it is domain-specific, so the host declares
it. The translation (everything after grain resolution) is not, so the
package owns it.

## The translation

For each event on a `project_all` action, `AshCompliance.Projector.translate/3`:

1. resolves the bundle through the `:bundle` MFA (the event is appended to
   the args — read the tenant id from its metadata and load the active
   `PolicyBundle`);
2. extracts facts with `AshCompliance.Projector.Facts` — by default from
   `event.metadata["facts"]`, as `[subject, "predicate", value]` triples;
   predicate names are matched against the bundle's fact schema by string, so
   no atom is created from event payload, and values are converted to the
   declared types exactly as the IR decoder does;
3. evaluates with `AshRules.evaluate/3`;
4. selects the requirements filed under the row's control (`gap ==
   control_id`) and combines them with the bundle's algorithm. `:not_applicable`
   is vacuous compliance for the row; *no requirement at all is `:unknown`* —
   a control nobody's rules manage is never silently green;
5. emits ops: status, severity (worst of the relevant findings), explanation,
   bundle hash, fired rule ids, breach-count increment on every noncompliant
   evaluation, and the timestamp transitions. `first_seen_at`,
   `last_seen_at` and `resolved_at` come from the *event's* timestamp, so a
   replay reproduces the timeline exactly.

The evaluation is recorded transactionally with the ops: the projector engine
wraps handler and ops in one database transaction, so the append-only
`ComplianceEvaluation` row can never disagree with the finding.

## Escape hatch

Events that should not be evaluated use the raw handler format of the
underlying DSL:

```elixir
project MyApp.Customer, :merged, fn event, finding ->
  [{:set, :subject_id, event.metadata["new_subject_id"]}]
end
```

## Testing

The engine drains asynchronously against its own connection, outside a test's
sandbox transaction. `AshCompliance.Testing.drain_sync/2` folds events
through the projector synchronously using exactly the same public machinery
(`upsert_grain`, `handle_event/2`, `apply_projection_ops`), inside the
caller's transaction. Replay determinism testing is then: drain the same
events into fresh tables twice, compare everything.
