<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# What it refuses

Compliance machinery earns trust by refusing loudly. Every refusal names the
offending artifact and what to do instead. This page is the list; the test
suite quotes each refusal.

## Compilation

* **Waiver of a non-waivable rule** — `waiver for rule "x" refused: the rule
  is declared in the non-waivable global layer and can never be waived`
* **Waiver of an undeclared rule** — `waiver for rule "x" targets a rule no
  active layer declares`
* **Replacement of anything but a supplement** — `replacement for rule "x"
  refused: it is declared in the :global_mandatory layer, which outranks
  approved overrides. Only tenant supplements can be replaced`
* **Replacement without a replacement rule set** — the override carries no
  `replacement_rules_json`, or it does not decode
* **Profile exclusion of an outranking rule** — `profile cannot exclude rule
  "x": it is declared in a layer that outranks profile refinements`
* **Profile refinement of a mandatory rule** — `profile cannot refine rule
  "x": it is declared in a mandatory layer that outranks profile refinements`
* **Parameterization** — `the rule IR has no parameter binding in v1 —
  precompute parameterized facts instead`
* **Operations on undeclared rules** — exclude/refine of a rule no active
  layer declares is refused, not silently dropped
* **Conflicting fact schemas** — contributing rule sets declaring the same
  fact with different types or absence semantics are refused
* **Any bundle that fails `AshRules.Verifier`** — unknown predicates, type
  mismatches, unbound variables, missing severity/outcome/gap: the same
  refusals `ash_rules` produces, surfaced at compile time

## Activation

* **Validate-before-activate** — a bundle whose stored JSON no longer decodes
  (tampered, or produced by an incompatible compiler) cannot be activated;
  the bundle stays `:compiled`
* **Lifecycle discipline** — a draft cannot be approved directly, an active
  revision cannot be revoked (only retired), a compiled bundle cannot be
  retired before activation
* **Tenant policy sets point only at active bundles** — setting the active
  bundle refuses anything else, with the actual status in the message

## Waivers

* **Open-ended waivers** — `a waiver requires expires_at — waivers are bounded
  time, never open-ended`
* **Inverted bounds** — `a waiver's expires_at must be after its starts_at`
* **No compensating controls** — `a waiver requires compensating_controls —
  a waived rule must be offset, not just ignored`
* **No approver** — `an override requires a named approver`
* **Replacement without content** — `a replacement requires
  replacement_rules_json — the serialized replacement rule set`

## Profiles

* **Approval-bearing operations** — `waive`/`replace` on a profile revision
  are refused with a pointer to `PolicyOverride`
* **Unknown operations, missing targets** — every operation is validated and
  normalized on create; the stored form is canonical

## Working memory

* **Undeclared predicates and type-violating values** — facts extracted from
  events are validated against the bundle's fact schema; a violation becomes
  an `:error` finding status with the reason in the explanation, never a
  silent pass
* **Unknown predicate names in event payloads** — matched against the schema
  by string; no atom is ever created from event payload

## What is deliberately absent

* **No API layer** — no JSON:API, no GraphQL. Resources, actions, the
  compiler and the projector only; wire exposure is the host's concern.
* **No ad-hoc inheritance** — there is no API that accepts a custom layer
  order or a caller-provided rule list; contributions come from resources
  only.
* **No events, no audit semantics of its own** — the event log belongs to
  AshEvents; the finding/evaluation split to the design. This package is the
  compliance layer, not the ledger.
