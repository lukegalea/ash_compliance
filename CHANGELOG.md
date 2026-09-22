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
- `AshCompliance.Compiler`: fixed layering precedence (non-waivable global >
  global mandatory > profile refinements > tenant strengthening > approved
  overrides > tenant supplements), per-layer combining algorithms, waiver
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
