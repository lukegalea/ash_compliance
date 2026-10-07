<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Layering and combining

## The fixed precedence

The design fixes the order once, in `AshCompliance.Compiler.Layer`:

| Rank | Layer                  | What it is                                                        |
|------|------------------------|-------------------------------------------------------------------|
| 1    | `global_non_waivable`  | The floor. Cannot be waived, cannot be replaced.                   |
| 2    | `global_mandatory`     | The baseline. May be waived with approval; never replaced.         |
| 3    | `profile_refinement`   | Catalog tailoring: exclude and refine operations apply here.       |
| 4    | `tenant_strengthening` | Tenant rules that tighten the baseline.                            |
| 5    | `approved_override`    | Approved replacements and waivers.                                 |
| 6    | `tenant_supplement`    | Tenant additions; cannot displace anything.                        |

Lower rank wins on conflict (same rule id). The order is data, not policy:
the compiler exposes no API that accepts a custom order, an inheritance
chain, or a caller-provided rule list. Contributions come from
`RuleSetRevision`, `ProfileRevision` and `PolicyOverride` rows only — ad-hoc
inheritance is refused by construction.

## What each layer may do

* **Replacements** (override kind `:replace`) may only displace rules ranked
  below the override layer — i.e. tenant supplements. Replacing a global
  mandatory rule is refused: `outranks approved overrides`.
* **Waivers** (override kind `:waive`) may target any layer except the
  non-waivable global one. A waiver requires `expires_at`, a named approver
  and compensating controls — the validations make an unaccountable waiver
  impossible to construct.
* **Profile excludes** apply at rank 3: they may remove rules from ranks 4–6
  (tenant layers), and are refused against anything that outranks the
  refinement layer.
* **Profile refines** patch a rule's severity and/or message in place — the
  rule id stays stable, so findings keep their filing. Refining a mandatory
  layer rule is refused.
* **Parameterization** is stored but refused at compile time in v1: the rule
  IR has no parameter binding. Precompute parameterized facts instead.

## Waivers and time

Waivers are evaluated against the *compile clock*. A waiver is in force while
its period contains the pinned instant — the half-open window
`starts_at <= now < expires_at`, stored as a PostgreSQL 18 temporal period on
the resource (Phase 3) and answered by the database, not by a hand-rolled
filter. Expired waivers are excluded from resolution entirely, which means a
waiver lapsing returns its rule to the effective bundle on the next compile —
no action required, no forgetting.

Because the in-force window is the resource's temporal period, two more
properties hold by construction:

* **Non-overlap is DB-enforced** — one waiver per (organization, rule,
  subject scope) may be in force at any instant; a second, overlapping
  grant is rejected by the database's `WITHOUT OVERLAPS` exclusion (the
  double-granted waiver is impossible).
* **Waivers can be future-dated** — a grant whose `starts_at` is in the
  future is invisible to compiles until that instant arrives; the write
  itself opens the future period, no scheduler involved.

Subject-scoped waivers exist as data (`scope_subject_type` / `scope_subject_id`)
but v1 compiles organization-wide bundles only; scoping a waiver to a single
subject is a host-level fact concern (or a future bundle parameter).

## Combining

Each layer declares an explicit combining algorithm (`deny_overrides` by
default; `permit_overrides`, `first_applicable` and `only_one_applicable`
available). The effective bundle carries the algorithm of the
highest-precedence layer that contributed a winning rule, with ties broken by
rule id for determinism. Hierarchical per-level folding is deferred until a
concrete program needs it; one algorithm per bundle keeps evaluation
auditable.
