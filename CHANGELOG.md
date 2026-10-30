<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [Unreleased]

Nothing has been released yet. Everything below is the initial body of work.

### Changed:

- **Bundles and rule sets compiled under a declared scheme can be stored.**
  `PolicyBundle :compile` takes optional `scheme`, `source` and `context`
  arguments, passed to `AshCompliance.Compiler.compile/1`, and records the
  scheme's module name in a new nullable `scheme` column (`nil` is the default
  scheme; with no new argument the compile call is exactly the old one). A
  source without its own lineage has the resolution's steps stored as a list.
  `RuleSetRevision` gains the same `scheme` column; its `layer` is checked
  against that scheme's layers (the six default ranks when `nil`). The active
  reads of both answer per scheme (no `scheme` argument: default-scheme rows
  only), so the default gather and a host projector never see another
  scheme's rows. Hosts generate a migration for the two columns.

- **Declared layer schemes, scoped contributions, pluggable contribution
  sources; the default six-rank scheme is unchanged.** `AshCompliance.Layering`
  is a behaviour a scheme module implements — ordered layers, per-layer
  operations with reach (`add`, `tighten`, `exclude`, `refine`, `waive`, `replace`,
  `parameterize`), protected operations, required scope keys and precedence
  semantics. `AshCompliance.Layering.Default` declares the six ranks;
  `AshCompliance.Compiler.Layer` answers from it. The compiler is split into
  a gather (`AshCompliance.Compiler.ContributionSource`, default
  `DatabaseSource`) and a pure merge (`AshCompliance.Compiler.resolve/3`,
  returning an `AshCompliance.Compiler.Resolution` with per-rule lineage and
  refusals). Contributions may be scoped and resolved against a context;
  `tighten` is refused unless strictly stronger; param placeholders in
  predicate values are bound so thresholds land in the bundle hash.
  `compile/1` with no `:scheme`/`:source` is unchanged: same bundles, hashes,
  lineage and refusal messages.
- **Phase 3 (temporal waivers)**: `PolicyOverride` is now a temporal resource
  (`strategy :context`, period attribute `valid_at`) — the in-force window IS
  the period. The stored `starts_at`/`expires_at` columns are replaced by the
  period (the names survive as derived calculations over `valid_at`); waiver
  grants map the `starts_at`/`expires_at` action arguments onto it, so expiry
  is physical (no version exists past `expires_at`) and future-dated waivers
  work with no scheduler. The `one_in_force_per_scope` identity is emitted as
  a `UNIQUE (... WITHOUT OVERLAPS)` GiST exclusion: one waiver per
  (organization, rule, subject scope) at any instant — the double-granted
  waiver is now rejected by the database. Requires `ash >= 3.34` and
  `ash_postgres >= 2.14` (the temporal core) on PostgreSQL 18.
- Dependency floors raised accordingly: `ash ~> 3.34`, `ash_postgres ~> 2.14`.

### Documentation:

- README: the "how it fits" control-plane/data-plane diagram, and screenshots
  from the reference integration (findings, the evaluation audit trail,
  rule-set layers, the subject-facing compliance columns), captured live from
  the `ash_enterprise` KYC demo.
- `LICENSES/MIT.txt` added alongside the root `LICENSE`, matching the
  first-party package convention; every documentation asset carries its
  `.license` sidecar.

### Changed:

- Code interfaces for every public action on `AshCompliance.Domain`; the
  compiler and OSCAL read paths moved from inline `Ash.Query` pipelines to
  named read actions; host-facing entry points (`AshCompliance.Oscal`,
  `AshCompliance.Testing.drain_sync/3`) thread optional `actor:`/`authorize?:`
  with the trusted-machinery bypass documented at each internal site.

### Features:

- `AshCompliance.status_for/2`: record-level compliance status as a read-only
  query — the same bundle evaluation the guard path exercises, surfaced for
  display instead of enforced. Returns per-rule verdicts (compliant /
  noncompliant / not_applicable, each with the rule id, severity and gap text
  the guard quotes on refusals) under an overall status, plus `message/1`
  rendering the guard's refusal vocabulary directly. Facts come from the host
  through the `AshCompliance.FactBuilder` contract (module, `{module,
  function}`, capture, or the record's own module); `:organization` accepts
  the established MFA form.
- `AshCompliance.Web.RulesetEditorLive`: the operator-facing ruleset editor.
  Hosts mount it with the `use` macro (domain, organization source, actor),
  exactly as `ash_decisions` mounts its designer. A structured form over
  facts and rules — no raw DSL text — that serializes through
  `AshRules.Ir.encode!` on every save and hydrates through
  `AshRules.Ir.decode`, with the verifier's diagnostics rendered inline and
  the toolbar wired 1:1 to the domain lifecycle (draft → validate → approve
  → activate → compile bundle → activate bundle). `phoenix_live_view`
  becomes a hard dependency for the same reason ash_decisions declares it.
- Control plane: catalogs, controls, profiles (tailoring operations as data),
  rule set revisions with a validated lifecycle, tenant policy sets,
  accountability-bearing policy overrides (waivers with bounded time,
  approver and compensating controls), control mappings — and the immutable,
  content-hashed `PolicyBundle` with compile and validate-before-activate.
- `AshCompliance.Compiler`: default layering precedence (non-waivable global >
  global mandatory > profile refinements > tenant strengthening > approved
  overrides > tenant supplements, declarable per scheme), per-layer combining algorithms, waiver
  expiry evaluated against the compile clock, loud refusal of overreach.
- `AshCompliance.Projector`: evaluator-to-ops translation over
  `ash_events_projections`, finding grain
  `[organization_id, control_id, subject_type, subject_id]`, transactional
  append-only `ComplianceEvaluation` per evaluation.
- Findings data plane: `Finding` ProjectionResource, `ComplianceEvaluation`,
  immutable `EvidenceArtifact` (hash, media type, collector, method, chain of
  custody, retention class).
- OSCAL interop: catalog/profile import and export plus
  `mix ash_compliance.import_oscal` / `mix ash_compliance.export_oscal`.
- `AshCompliance.Workers.NotifyProjectors`: Oban recovery net for missed
  projector wake-ups (compiled only when Oban is a dependency).
