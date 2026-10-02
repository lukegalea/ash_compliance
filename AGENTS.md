<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# AGENTS.md

This is `ash_compliance`, the compliance control plane and data plane for
Ash, wired together by an `ash_rules` bundle hash.

## Agent constitution

This repository follows `AGENT_PRINCIPLES.md` v1.5, the agent constitution of
the ai-sdlc platform:
<https://github.com/lukegalea/ai-sdlc/blob/master/AGENT_PRINCIPLES.md>.
That file is the root policy for every agent session here. This file adds the
rules of this repository only. It does not replace or weaken the root policy.
If a rule here contradicts a security rule there, stop and ask a human. The
link opens only for people with access to the ai-sdlc repository. If you cannot
open it, these rules from it still apply:

- Do not approve your own work. A human approves every merge and every release.
- Do not put a secret in a file, a commit, a log, or a prompt.
- Do not publish anything outside this repository without human approval.
- Do not say that work is verified unless a CI result shows it.

## Project guidelines

- Rule changes are events, not edits. Every effective rule set is a compiled,
  hash-pinned bundle.
- The layering precedence is fixed: non-waivable global, then global
  mandatory, then profile refinements, then tenant strengthening, then
  approved replacements and waivers, then tenant supplements. The compiler
  refuses ad-hoc inheritance, overreach, and weakening.
- The finding (the projection, "now") and the `ComplianceEvaluation` record
  (append-only, "why") are different artifacts. No code path rewrites either.
- Missing evidence is never compliance. `unknown` never collapses to
  `compliant`.
- The package ships no policy blocks. The host owns authorization.
  `authorize?: false` appears only in trusted machinery, with a justification
  comment at each site.
- Tenancy is an explicit `organization_id` attribute, not Ash multitenancy.

## Before you finish

CI runs `mix compile --warnings-as-errors`, `mix test`,
`mix format --check-formatted`, and `mix credo --strict`. Run all four before
you finish.

## Generated sections

This repository does not run `mix usage_rules.sync` today. If it starts to, the
task adds its own section at the end of this file, between its
`usage-rules-start` and `usage-rules-end` markers. Do not edit text inside
those markers. Keep the rules of this repository above them.
