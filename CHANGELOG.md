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

### Features:

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
