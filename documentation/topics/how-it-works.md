<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# How it works

`ash_compliance` is two planes joined by a bundle hash.

## The control plane

The control plane is where the compliance program is authored, tailored and
approved:

* **Catalogs** hold controls. A `Control` is the stable semantic identity
  (`control_id`); a `ControlRevision` is the versioned text, parameters and
  citations. Findings reference controls by id, so control text can be
  revised without orphaning findings.
* **Profiles** tailor catalogs. A `ProfileRevision` stores tailoring
  *operations* as data (include, exclude, parameterize, refine, supplement) —
  never logic. Approval-bearing operations (replace, waive) cannot live in a
  profile; they belong in `PolicyOverride`, where accountability is enforced.
* **Rule set revisions** pin compiled `ash_rules` bundles to a layer and a
  lifecycle: `draft → validated → approved → active → retired | revoked`.
  Only `:active` revisions participate in compilation.
* **Waivers and replacements** (`PolicyOverride`) carry approver, reason,
  time bounds and compensating controls. The validations refuse an
  unaccountable waiver; the compiler refuses waivers against the non-waivable
  layer and replacements of anything but tenant supplements.

`PolicyBundle.compile` runs `AshCompliance.Compiler` inside the action: the
compiler fetches the active rule set revisions (global + tenant), the
tenant policy set's profile revisions, and the still-valid overrides, resolves
them through the fixed precedence, validates the result through
`AshRules.Verifier`, and stores the serialized bundle with its content hash
and a manifest revision string built from the contributing ids. The same
input state always compiles to the same hash.

`PolicyBundle.activate` is validate-before-activate: the stored JSON is
decoded through `AshRules.Ir.decode/1` (which re-runs the verifiers) before
the bundle may go live. A tampered or incompatible bundle cannot be
activated; a tenant policy set can only point at an active bundle.

## The data plane

The data plane answers the operational question — *is this subject compliant
with this control right now?* — and records why.

`AshCompliance.Projector` wraps the `ash_events_projections` projector
contract. Each qualifying domain event:

1. resolves the tenant's active bundle,
2. hydrates facts from the event (`AshCompliance.Projector.Facts`),
3. evaluates through `AshRules.evaluate/3`,
4. selects the requirements filed under the finding's control (rules whose
   gap reference matches `control_id`) and combines them,
5. updates the `Finding` row and appends a `ComplianceEvaluation` — in one
   database transaction.

The finding is the *now*: status, severity, breach count, explanation, and
the `first_seen_at` / `last_seen_at` / `resolved_at` timeline derived from
event timestamps, so a replay reproduces them exactly. The evaluation is the
*decision record*: bundle hash and revision, fact snapshot hash, outcome,
missing facts, evaluator version, correlation id, source event id. A replay
reproduces those too — that is the replay-determinism acceptance bar, and it
is asserted by the test suite.

## The seam

The bundle hash is the only thing the two planes share. Findings and
evaluations reference the hash; the hash identifies the exact rules, schema
and combining algorithm that produced every outcome. Nothing in the data
plane ever re-derives rules, and nothing in the control plane reads findings.
