<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Layering and combining

## Declared schemes

A layering scheme is a module implementing `AshCompliance.Layering`. It
declares, as data:

* **the layers**, outermost (highest precedence) first;
* **what each layer may do** — the operations a contribution at that layer
  may perform, each with a *reach* (which target layers it may touch), plus
  operations rules declared at that layer refuse whatever the editor's reach
  (`protected`), and an optional `scope_key` every contribution there must
  carry;
* **precedence semantics** — which declaration stands on a same-id conflict,
  whether edits cascade outer→inner or are checked against the winning
  declarations, and whether the first refusal stops resolution;
* **how a scope matches a context**, and **what "strictly stronger" means**
  for a param (both with defaults).

The scheme is code, reviewed like code, and passed explicitly
(`AshCompliance.Compiler.compile(scheme: ...)`,
`AshCompliance.Compiler.resolve(contributions, scheme, context)`). There is
no application-env switch and no runtime-supplied order: a host may run two
schemes side by side (a KYC slice on the six ranks, a vendor-requirements
slice on its own scope layers), and the order a bundle was compiled under is
always the order a reviewer read. Ad-hoc inheritance is still refused: a
contribution's precedence comes only from the layer it declares, never from
who compiled or when.

`AshCompliance.Layering.Default` is the six-rank scheme below.
`AshCompliance.Compiler.compile/1` with no `:scheme` uses it, and on the
default path the bundle, its content hash, the lineage and the refusal
messages are exactly what they were before schemes were declarable.

### Operations

| Op             | What it does                                                                    |
|----------------|---------------------------------------------------------------------------------|
| `add`          | Declares a rule, optionally with `params` and each param's `strength` direction |
| `tighten`      | Makes a declared rule's params **strictly** stronger; anything else is refused  |
| `exclude`      | Removes a rule from what applies (OSCAL profile vocabulary; "remove")           |
| `refine`       | Patches a rule's severity and/or message; the rule id stays stable              |
| `waive`        | An approved, time-bounded exclusion                                             |
| `replace`      | Displaces a rule with approved replacement rules                                |
| `parameterize` | Sets params without the strictly-stronger check                                 |

A layer that does not list an operation may not perform it; the refusal is
`op_not_allowed`.

### Gather, then merge

Compilation is two steps:

1. **Gather.** An `AshCompliance.Compiler.ContributionSource` reads
   contributions. The default, `AshCompliance.Compiler.DatabaseSource`, reads
   active `RuleSetRevision` rows (`add` at their layer), in-force
   `PolicyOverride` rows (`waive`/`replace` at `approved_override`) and the
   tenant policy set's `ProfileRevision` operations (`exclude`, `refine`,
   `parameterize` at `profile_refinement`). A source never decides precedence.
2. **Merge.** `AshCompliance.Compiler.resolve/3` is pure: contributions,
   scheme and context in; an `AshCompliance.Compiler.Resolution` out — the
   effective rules, the effective params, per-rule lineage (each step's layer,
   op, source and params) and the refusals.

"What does this job need?" is always a resolved read — `resolve/3` against
the job's context — and is never stored. Only a compiled, activated
`PolicyBundle` is evaluated (usage rule 1).

### Scope and context

A contribution may carry a `scope` (`%{property_group: id}`); a resolution
runs against a `context` (`%{pmc: id, property_group: [ids], property: id,
contract: id, job: id}`). By default a scoped contribution applies when every
scope key is present in the context with an overlapping value; an unscoped
one applies everywhere. Contributions that do not match are *dropped*, not
refused — which is what makes a removal narrow: a job-scoped exclusion is
invisible to a PMC-level read, so it can never remove a rule at an outer
layer. A layer with a `scope_key` refuses unscoped contributions outright,
because an unscoped job edit would otherwise apply to every job.

### Precedence semantics

* `declarations: :outer_wins` (default) — on a same-id `add`, the outer
  layer's declaration stands. Under `:cascade` an inner re-declaration that
  differs is refused (`already_declared`: use `tighten`); an identical one is
  a no-op. `:inner_wins` lets the inner declaration stand.
* `edits: :cascade` (default) — contributions apply outermost layer first
  (stable within a layer), each against the result so far: a second
  `tighten` must beat the first, an exclusion removes what outer layers
  built, and an inner layer may `add` a rule an outer one excluded.
  `edits: :against_declarations` — every `add` is collected first and each
  edit is checked, in source order, against the winning declaration; a
  replacement's rules join the declarations at the editor's layer.
* `refusals: :all` (default) — refused contributions are skipped and every
  refusal is reported (useful for explaining a resolution). `:first` stops
  at the first refusal. `compile/1` refuses any resolution with refusals.

### Requirements with thresholds

A requirement is an `AshRules` rule plus, when it has a threshold, params:
`add` declares `params: %{min_amount: 1_000_000}` and
`strength: %{min_amount: :at_least}`. A `tighten` must name only declared
params and each must be strictly stronger under its direction (`:at_least`,
`:at_most`, `:superset`, `{:ranked, [weakest, ..., strongest]}`); equal or
weaker is refused (`not_stronger`). A presence requirement has no params and
cannot be tightened.

The rule IR has no comparison operator, so a threshold reaches evaluation
through the rule itself: a predicate value may be a param placeholder
(`AshCompliance.Layering.param(:min_amount)`, JSON `{"param": "min_amount"}`),
and resolution binds it to the effective value —
`neg(:vendor, :gl_coverage_at_least, 2_000_000)`. The threshold is then part
of the rule, so it is part of the bundle's content hash, and the host's fact
builder emits `{vendor, :gl_coverage_at_least, 2_000_000}` when the vendor's
coverage meets it. An unbound placeholder is refused (`unbound_param`).

## The default scheme

`AshCompliance.Layering.Default`, which `AshCompliance.Compiler.Layer`
answers from:

| Rank | Layer                  | What it is                                                        |
|------|------------------------|-------------------------------------------------------------------|
| 1    | `global_non_waivable`  | The floor. Cannot be waived, cannot be replaced.                   |
| 2    | `global_mandatory`     | The baseline. May be waived with approval; never replaced.         |
| 3    | `profile_refinement`   | Catalog tailoring: exclude and refine operations apply here.       |
| 4    | `tenant_strengthening` | Tenant rules that tighten the baseline.                            |
| 5    | `approved_override`    | Approved replacements and waivers.                                 |
| 6    | `tenant_supplement`    | Tenant additions; cannot displace anything.                        |

Lower rank wins on conflict (same rule id), edits are checked against the
winning declarations, and the first refusal stops the compile
(`declarations: :outer_wins, edits: :against_declarations, refusals: :first`).

### What each layer may do

* **Replacements** (override kind `:replace`, reach `:inner` from
  `approved_override`) may only displace rules ranked below the override
  layer — i.e. tenant supplements. Replacing a global mandatory rule is
  refused: `outranks approved overrides`.
* **Waivers** (override kind `:waive`, reach `:any`) may target any layer
  except the non-waivable global one, which declares `protected: [:waive]`. A
  waiver requires `expires_at`, a named approver and compensating controls —
  the validations make an unaccountable waiver impossible to construct.
* **Profile excludes** apply at rank 3 with reach `:inner`: they may remove
  rules from ranks 4–6 (tenant layers), and are refused against anything that
  outranks the refinement layer.
* **Profile refines** (reach `:self_and_inner`) patch a rule's severity
  and/or message in place — the rule id stays stable, so findings keep their
  filing. Refining a mandatory layer rule is refused.
* **Parameterization and tightening** are declared on no layer, so both are
  refused: precompute parameterized facts instead, or declare a scheme that
  permits `tighten`.

## Waivers and time

Waivers are evaluated against the *compile clock*. A waiver is in force while
its period contains the pinned instant — the half-open window
`starts_at <= now < expires_at`, stored as a PostgreSQL 18 temporal period on
the resource (Phase 3) and answered by the database, not by a hand-rolled
filter. Expired waivers are excluded from the gather entirely, which means a
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
but the database source compiles organization-wide bundles only, and emits
every contribution unscoped; scoping a waiver to a single subject is a
host-level fact concern, or a host `ContributionSource` that maps it to a
contribution `scope`.

## Combining

Each contribution carries an explicit combining algorithm (`deny_overrides`
by default; `permit_overrides`, `first_applicable` and `only_one_applicable`
available). The effective bundle carries the algorithm of the
highest-precedence layer that contributed a winning rule, with ties broken by
rule id for determinism. Hierarchical per-level folding is deferred until a
concrete program needs it; one algorithm per bundle keeps evaluation
auditable.
