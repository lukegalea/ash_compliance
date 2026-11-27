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

Requires Elixir 1.20 or later.

### Added:

- Reference schemes a host configures for the control file
  (`AshCompliance.Ownership.ReferenceScheme`,
  `config :ash_compliance, reference_schemes: %{"journey" => MyApp.JourneyReference}`):
  a row may name `scheme:value`, and `Ownership.Resolver` (so `Ownership.Check` and
  `mix ash_compliance.controls.check`) asks the scheme's module whether the reference
  resolves and whether a producer records evidence for a criterion. The built-in
  `module:`, `mix:` and `file:` schemes cannot be replaced. **Adopting:** nothing changes
  until a host configures a scheme.
- `environment_class` on evidence: the class of the environment an artifact was
  collected in, in `AshCompliance.Boundary`'s terms (`:production` or `:non_production`,
  `AshCompliance.Boundary.Environment.classes/0`). `Evidence.record/4` takes it as the
  `:environment_class` option, the evidence archive carries it, and the audit package
  reports it per artifact. The freshness evaluator never counts a `:non_production`
  artifact: it proves the code ran, not that the control operates, so a source with only
  such artifacts is `:unknown` with reason `:non_production`. An artifact that names no
  class counts as before. **Adopting:** a host adds the column to its hot and archive
  tables (`mix ash.codegen`); a producer that runs outside production passes
  `environment_class: :non_production`.

- `AshCompliance.Status.questions/2` (delegated as `AshCompliance.status_questions/2`):
  the absences a person must answer before the `:unknown` rules of a status can decide.
  One string-keyed entry per (rule, subject, predicate) for each absence in
  `missing_facts` that the schema declares `missing: :unknown` and an unknown rule
  probes, carrying the rule id, message, evidence and the fact's schema description as
  the question. It takes the bundle the status was evaluated against, in any form
  `status_for/2` accepts, and refuses one with another hash. An empty list is not
  compliance: an `:unknown` status still blocks. **Adopting:** a host that filtered
  `missing_facts` itself to build an interview can call `questions/2` instead.

- OSCAL assessment results. `AshCompliance.Ownership.Package.sections(org, from, to, opts)`
  assembles the compliance plane's part of an audit package: the criteria in scope
  (`categories:`) with the host's control-file row for each (`controls_file:`), the
  evidence collected in the period from the hot table and the archive, each re-checked
  against its hash, each criterion's freshness at the end of the period with the waivers
  in force then, and the findings open in the period. `extra_observations:` and
  `extra_findings:` carry the host's own as plain maps.
  `AshCompliance.Oscal.AssessmentResults.build(sections, meta)` turns them into an OSCAL
  1.2.3 assessment-results document. It never says `satisfied`: unknown is a
  `not-satisfied` finding with reason `other`. Identifiers are version 5 UUIDs derived
  from what they name, and properties use `meta.namespace`.
  `AshCompliance.Oscal.AssessmentResults.validate(document)` returns `:ok` or
  `{:error, errors}` against NIST's schema, which ships unchanged with its CC0 licence in
  `priv/oscal/1.2.3/`, so a host can validate the document it builds, its own extra
  observations and findings included. It needs `jsv`, an optional dependency, and raises
  saying so without it.

- The evidence archive. `use AshCompliance.Resources, {:evidence_archive, table:, repo:}`
  builds it on the host's own resource, so the host keeps its domain, policies and table
  name (`:guard_function` names the guard trigger's function). It has the hot table's
  columns plus `archived_at`, no write action, and a trigger that refuses every update and
  any delete younger than 400 days. Name it with `config :ash_compliance,
  evidence_archive: ...`. `AshCompliance.Ownership.Retention.archive/1` moves artifacts
  older than `:hot_days` (at least 90) by a copy verified column by column and by hash
  before the hot rows are deleted, and keeps the newest artifact of each organization,
  control and collector hot. `purge/1` deletes archived artifacts only past a given
  `:purge_after_days` (at least 400). Both record each step in an optional `:archive_run`
  ledger. `Evidence.for_control/3` reads the hot table and the archive together, and the
  freshness sweep reads through it, so archiving never changes what a sweep finds.
  Requires a host migration for the archive table (`mix ash.codegen`).

- `AshCompliance.RuleSet.Diff`: `diff(old, new)` compares two rule set revisions over the bundles they pin, not the JSON text. It reports the layer and combining algorithm, each rule by id property by property, and each fact by name, as plain maps (`aspect`, `kind`, `subject`, `option`, `from`, `to`). `aspects/0` lists what it compares with English labels. A bundle that does not decode is `{:error, :unreadable_bundle}`, not an empty rule set.

- `Processes.Completion.complete/4` option `:approvals_organization_id`: judge the permitted approval in one organization while filing the evidence in another.

- `EvidenceArtifact.content` and `Evidence.record(..., store_content: true)`: an artifact can keep the bytes its hash pins. Stored bytes must match the hash at create; `Evidence.verify/1` re-checks them. Off by default; existing rows are unchanged. Requires a host migration adding a nullable `content` binary column.

- `AshCompliance.Boundary`: a Spark extension that declares environments (`:production`, or
  `:non_production` under a data ceiling) and resources (managed or data source). It knows
  nothing about audits. `mix ash.codegen` writes `boundary.auto.tfvars.json`,
  `infra.assertions.json` and `boundary.snapshot.json` as deterministic JSON, and `--check`
  fails when any is missing or stale. A declaration can use it alone with
  `use AshCompliance.Boundary.Production`.
- `AshCompliance.Boundary.Controls`: a separate extension that reads those facts. It adds
  `audited_environments` and control links, refuses a control that no audited production
  resource satisfies, and writes `control-map.json` and `controls.snapshot.json`.
  `AshCompliance.Boundary.Declaration` includes both.
- SOC 2 ownership contract: the 61 Trust Services Criteria as data, a control-file
  schema (`"criteria"` rows), `mix ash_compliance.controls.check`, an append-only
  evidence writer for `EvidenceArtifact`, a pure freshness evaluator, and the
  `AshCompliance.Workers.EvidenceFreshness` Oban worker. Stale or missing evidence is
  `:unknown` and raises a finding; only an approved, expiring waiver silences it.

- Operator process templates: nineteen BPMN documents and two DMN decisions under
  `priv/`, a shared separation-of-duties decision that refuses self-approval and
  approval through a delegation (every refusal is recorded as an
  `ApprovalAttempt`), `Processes.Completion` which writes evidence only for a
  finished and approved instance, and `Processes.Overdue` which raises a finding
  for an overdue or unreadable task. `ash_bpmn` and `ash_decisions` are optional
  dependencies used to compile and verify the shipped documents in tests.
- `AccessReview`: campaigns that merge several `AccessReview.Source`s into one
  effective-access row per person, with append-only sealed decisions. A source that
  errors, is empty or is malformed makes the campaign incomplete, and an
  incomplete or partly decided campaign cannot be closed.

- `PolicyOverride.requested_by`, required on create and refused when equal to the approver
  (the shared separation-of-duties decision). Hosts generate a migration for the nullable
  column. A freshness waiver silences only with a distinct requester and a window of at most
  90 days. `mix ash_compliance.controls.check --require-producer-proof` makes a producer
  declare the criteria it records evidence for via `evidence_controls/0`; an enforced row
  with no `test_ref` is `:unknown`, not `:owned`. The access-review close summary counts
  the latest decision by instant, not by struct term order.

### Changed:

- **Contract change: a passed `AshRules.Ir.Bundle` is normalised to its stored
  spelling.** `AshCompliance.status_for/2` (`:bundle`) and
  `AshCompliance.Projector.translate/4` put an IR bundle through the IR codec
  (encode, then decode with the verifiers) before evaluating it. A bundle
  compiled from the DSL keeps atom subjects (`has(:application, ...)`), while the
  `AshCompliance.FactBuilder` contract emits string subjects, so until now
  every rule of such a bundle read as `:not_applicable` and nothing was asked.
  It now evaluates exactly as the same bundle read back from storage. The
  bundle hash and revision are unchanged; a decoded bundle comes back equal; a
  stored `PolicyBundle` is unaffected. A bundle that cannot be normalised is
  `{:error, {:invalid_bundle, reason}}` from `status_for/2`, and error ops from
  the projector. A caller that passed a DSL bundle together with atom-subject
  facts must emit string subjects, as the fact-builder contract already says.
  **Adopting:** a host that round-trips a bundle through `AshRules.Ir.encode!/1`
  and `decode!/1` before passing it can delete that step.

- The evidence archive's 400 days count from when an artifact was recorded: the later of `collected_at`, which the collector supplies, and `inserted_at`, which it cannot. `Retention.purge/1` and the archive's guard trigger both use it, so a back-dated `collected_at` no longer makes an artifact purgeable early. The guard trigger's statement names a digest of the function, so `mix ash.codegen` drops the trigger before the function and recreates both, instead of a `DROP FUNCTION` the trigger depends on. **Host step:** run `mix ash.codegen` to regenerate both.

- `ApprovalAttempt :record` no longer accepts `outcome`, `reason` or `decision_hash`: the row asks the separation-of-duties decision itself, so a caller cannot record a permit the decision would not give. `Processes.Approval.record/4` is now `record/3` (no verdict argument). **Host step:** drop the verdict argument at each `Approval.record` call.

- `ApprovalAttempt` and `PolicyOverride` carry `Ash.Policy.Authorizer`: reads are open; every create, update or destroy from an actor is forbidden. **Host step:** write them through `Processes.Approval`/`Processes.Gate`, or from trusted code with `authorize?: false` (seeds, fixtures, and the host action that grants a waiver under its own policies).

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
