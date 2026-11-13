<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Operator processes and access reviews

Some controls cannot be done by software: a person has to approve, review or
attest. This package ships the processes that carry those controls as BPMN and
DMN documents, and the pieces that make a finished process count as evidence
and an unfinished one count as overdue. Software here still never claims
compliance. A completed process is *evidenced*; it is not *good*.

## What ships

Nineteen process templates under `priv/processes/`, listed by
`AshCompliance.Processes.Templates.all/0`:

| Template | Trigger | Criteria |
|---|---|---|
| `effective_access_review` | quarterly | CC6.2, CC6.3 |
| `access_request` | per request | CC6.1, CC6.2, CC6.3 |
| `break_glass` | per use | CC6.1, CC8.1 |
| `impersonation` | per use | CC6.1 |
| `emergency_change_review` | per use | CC8.1 |
| `custody_cutover_approval` | per cutover | CC6.3, CC8.1 |
| `divergence_signoff` | per change | CC8.1 |
| `override_waiver_approval` | per request | CC4.2, CC5.3 |
| `log_alert_review` | weekly | CC7.2 |
| `vulnerability_triage` | per finding | CC7.1, CC4.2 |
| `incident_response` | per incident | CC7.3, CC7.4, CC7.5 |
| `restore_test_attestation` | quarterly | A1.3 |
| `retention_disposal_approval` | per schedule | C1.2 |
| `policy_review_acknowledgement` | annual | CC1.1, CC2.2, CC5.3 |
| `oversight_meeting` | per meeting | CC1.2 |
| `training_attestation` | annual | CC1.4, CC1.5 |
| `risk_register_review` | monthly | CC3.1 to CC3.4, CC5.1 |
| `vendor_review` | annual | CC9.1, CC9.2 |
| `customer_notification` | per change | CC2.3 |

Two decisions under `priv/decisions/`: `compliance.separation_of_duties` and
`compliance.triage_routing`.

The wording is generic. Roles are names such as `approver`, `security_reviewer`
and `incident_lead`; the host binds them to its own groups. The templates call
five actions (`AshCompliance.Processes.Templates.actions/0`) that the host's
action invoker implements, and two decisions
(`AshCompliance.Processes.Templates.decisions/0`) that the host publishes.

## Optional engines

`ash_bpmn` and `ash_decisions` are optional dependencies of this package and are
used in its tests: every template is compiled with the real BPMN compiler, with
the action and decision catalogues checked at publish time, and both decisions
are compiled and verified with the real DMN compiler. A host that runs the
processes depends on them itself.

To adopt a template, copy it from `priv/processes/` into the host's tree, publish
it, and cite the file in the control row's `operating_process`.
`Templates.reference/1` gives the conventional reference string.

## Separation of duties

Every approval step in every template does three things:

1. excludes the requester from the task's candidates
2. asks `compliance.separation_of_duties` whether approver and requester are
   different people, after the task is decided
3. ends the process as `refused` unless the answer is `permit`

The decision refuses on a missing requester or approver, an unrecorded
delegation chain, approver equal to requester, and the requester appearing
anywhere in the delegation chain. A rule with no conditions at the end refuses
anything the rules above did not positively permit. Principals are compared as
trimmed, lower-cased text.

A decision decides; it does not enforce. `AshCompliance.Processes.Approval`
enforces:

```elixir
Approval.decide(org_id, %{
  process_key: "compliance.access_request",
  subject_id: instance_id,
  requester_id: "alice",
  approver_id: "bob",
  delegators: []
})
#=> {:ok, attempt}
#=> {:error, {:refused, "self_approval", attempt}}
```

Every attempt, permitted or refused, is an
`AshCompliance.Resources.ApprovalAttempt`: who, for whom, through which
delegation chain, and the hash of the decision document that answered. The shipped
document is evaluated directly, pinned by its hash, so editing a published copy
cannot weaken the gate. If the engine is not installed, the model will not load,
the evaluation errors or the answer has an unrecognised shape, the check is
refused.

An approval that cannot be recorded is not an approval.

The attempt row asks the decision itself when it is written: `outcome`,
`reason` and `decision_hash` are not inputs to `ApprovalAttempt :record`, so a
row cannot claim a permit the decision did not give. No actor may write an
attempt (the resource's policies refuse it); `Approval.record/3` and the
`Gate` write them as trusted machinery.

## Completion writes evidence

```elixir
Completion.complete(org_id, "access_request", %{
  instance_id: instance_id,
  completed_by: "bob",
  outcome: "completed",
  summary: %{...}
}, collector: "file:priv/processes/access_request.bpmn")
```

One artifact per criterion the template supports, written through
`AshCompliance.Ownership.Evidence`. The collector must equal the string the
control row declares for the process, because the freshness evaluator counts only
artifacts from a source the row declares.

Nothing is written for an outcome other than `completed`, for a template with an
approval when no permitted approval attempt is on record for that instance, for
a blank instance, completer or collector, or for a summary that cannot be
encoded. A rejected, refused or expired process therefore leaves the control
reading as stale.

Some templates support criteria outside the security category (A1.3, C1.2).
Include those categories in the freshness sweep or they are never evaluated.

## Overdue tasks raise findings

A host implements `AshCompliance.Processes.TaskSource` over its process engine's
open tasks. `AshCompliance.Processes.Overdue.sweep/3` (or the
`AshCompliance.Workers.ProcessOverdue` Oban worker) files a `:unknown` finding
for every criterion of the task's template, under the grain
`{organization, criterion, "process_overdue", task id}`.

A task with a missing or malformed due time is overdue. A task for a process no
template defines is filed against `process:unclassified`. A source that errors,
raises or answers with something that is not a list files a finding against
`process:task-source` and resolves nothing. When a task closes, its finding is
resolved on the next successful sweep and stays `:unknown`.

A process that never starts is not a task and is not seen here. It shows as stale
evidence in the freshness sweep.

## Access review campaigns

`AshCompliance.AccessReview` runs the quarterly effective-access review.

```elixir
{:ok, campaign} =
  AccessReview.open(org_id, %{name: "Quarterly", period: "2026-Q4", opened_by: "owner"},
    [MyApp.AppGrants, MyApp.CodeHostMembers, MyApp.CloudRoles])

AccessReview.decide(row_id, "reviewer", :revoke, "left the team")

AccessReview.close(campaign.id, "signer", collector: "file:priv/processes/effective_access_review.bpmn")
```

**Sources.** Each authority implements `AshCompliance.AccessReview.Source`:
an `id/0` and an `entries/1` returning `{:ok, entries}`. Entries are merged by
person key (trimmed, lower-cased) into one row per person, listing each source and
its grants.

**Incomplete is not empty.** A source that errors, raises, exits, times out,
returns no entries, or returns a malformed entry makes the campaign
`:incomplete`. The status is derived from the recorded source results and cannot
be set by the caller. An incomplete campaign accepts no decisions and cannot be
closed. The rows from sources that did answer are kept so the failure can be
investigated.

**Decisions are append-only.** A decision (`:keep` or `:revoke`) has no update or
destroy action, carries a seal over its own fields, and records the digest of the
row it was made on. A changed mind is a new decision; the latest is effective. A
reviewer cannot decide on their own access or on the access of someone they are
acting for: the same separation decision is asked, and the refused attempt is
recorded.

**Closing.** A campaign closes only when it is open, has rows, every row has a
decision, every seal and row digest still matches, and the signer is not the person
who opened it or anyone that person delegated through. A campaign altered in the
database after the fact fails its seals and refuses to close. The closing
writes evidence for CC6.2 and CC6.3; if the evidence cannot be written the error
says the campaign closed without it.

### Hardening the tables

The resources expose no way to change or remove an attempt or a decision. To make
that physical, add a trigger in the host migration:

```sql
CREATE FUNCTION ash_compliance_refuse_change() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'append-only: % on % is not allowed', TG_OP, TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER decisions_append_only
BEFORE UPDATE OR DELETE ON ash_compliance_access_review_decisions
FOR EACH ROW EXECUTE FUNCTION ash_compliance_refuse_change();
```

Without the trigger the seal still catches an edit when the campaign closes.

## Limits

A completed task is not a good review. These artifacts show a process ran, who
finished it and that an approval by a different person is on record. An auditor
still tests that people did the work.
