<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Ownership and freshness

A control file says who owns each SOC 2 criterion and how it is evidenced.
This package checks that file against the full criteria catalogue and keeps
asking whether the evidence is still current. Software here never claims
compliance. Its outputs are *owned*, *evidenced* or *unknown*.

## The catalogue

`AshCompliance.Ownership.Criteria` lists all 61 Trust Services Criteria
(2017) by id and category, each with a short title written for this package.
It is data, and a host cannot remove an entry. A host chooses which
*categories* are in its audit.

| Category | Ids | Count |
|---|---|---|
| `:security` | CC1.1 to CC9.2 | 33 |
| `:availability` | A1.1 to A1.3 | 3 |
| `:processing_integrity` | PI1.1 to PI1.5 | 5 |
| `:confidentiality` | C1.1 to C1.2 | 2 |
| `:privacy` | P1.1 to P8.1 | 18 |

## The control file

Ownership rows go under a top-level `"criteria"` key, beside whatever the file
already holds (`"frameworks"`, `"controls"`, `"$comment"`). A file without the
key stays valid; the checker reports each criterion as missing.

```json
{
  "criteria": [
    {
      "id": "CC6.1",
      "class": "PLATFORM-EVIDENCED",
      "applicability": "applicable",
      "frequency": "daily",
      "owner_role": "Head of Engineering",
      "evidence_producer": "module:MyApp.Evidence.AccessSnapshot",
      "operating_process": "file:docs/runbooks/access-review.md",
      "test_ref": "file:test/my_app/access_test.exs"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `class` | `PLATFORM-ENFORCED`, `PLATFORM-EVIDENCED`, `HOST-APP`, `INFRA`, `VENDOR` or `ORG` |
| `applicability` | `applicable`, or `not_applicable` with a `rationale` |
| `frequency` | `continuous`, `daily`, `weekly`, `monthly`, `quarterly`, `semiannual` or `annual` |
| `owner_role` | the accountable role |
| `evidence_producer` | the code or system that collects evidence: `module:`, `mix:` or `file:` |
| `operating_process` | the process people follow, same reference forms |
| `test_ref` | the test or check that proves the control, same reference forms |
| `vendor_ref` | for `VENDOR` rows, the vendor report relied on |
| `complementary_controls` | for `VENDOR` rows, the criteria in this file that cover what the vendor leaves to you |

A row never carries `status`. Status is derived from evidence every time it is
asked, so a stored one would be a claim nothing keeps true. The checker
rejects the key.

## `mix ash_compliance.controls.check`

```
mix ash_compliance.controls.check
mix ash_compliance.controls.check --file docs/controls.json --categories security,availability
mix ash_compliance.controls.check --require-producer-proof
mix ash_compliance.controls.check --report
```

Fails, naming each row, on a missing criterion, no owner role, an
unresolvable producer or process, no `test_ref`, a `PLATFORM-*` row whose test
or producer does not resolve, a recurring `ORG` or `HOST-APP` row with no
process, and a `VENDOR` row with no complementary controls. `--report` lists
every problem and exits 0 so a host can adopt the check before the file is
finished. A clean run says the file is complete, not that anything operates.

### Turning on producer proof

By default a producer passes when its module, Mix task or file exists. That
proves the name resolves, not that anything records evidence, so a file can
reach zero problems with no producer wired. A host turns the stronger check on
with `--require-producer-proof` (or `require_producer_proof: true` to
`Check.run/2`). Each `module:` or `mix:` producer must then export
`evidence_controls/0`, returning the criterion ids it records artifacts for:

```elixir
def evidence_controls, do: ["CC6.1", "CC6.3"]
```

A `file:` producer can never declare this and is reported as
`:unproven_producer`. Declare it in the same change that makes the producer
call the evidence writer, and run the flag in CI. Rows whose producers have
not been wired yet are the gap list.

## Evidence

`AshCompliance.Ownership.Evidence.record/4` writes an `EvidenceArtifact`: dated,
with the SHA-256 of the content, naming its producer. The producer name is the
same reference the control row carries. `EvidenceArtifact` has no update or
destroy action; a correction is a new artifact. `collect/4` runs a producer
function and records what it returns. A producer that errors, raises or
returns nothing leaves no artifact, so the control reads as missing or stale.

## Freshness

`AshCompliance.Ownership.Freshness` is a pure evaluator. For each in-scope
criterion it returns one of:

| State | When |
|---|---|
| `:evidenced` | every source the row declares (producer, process, vendor reference) has a well-formed artifact inside the frequency window |
| `:owned` | a `PLATFORM-ENFORCED` row with no evidence source |
| `:not_applicable` | declared so, with a rationale |
| `:unknown` | everything else |

`:unknown` covers: control file missing or malformed, no row, an unknown class
or frequency, no owner, no artifact, a stale artifact, a future-dated one, a
malformed timestamp or hash, and an artifact from a producer the row does not
name. A process that did not run inside its window is an overdue source, and
shows the same way.

## The worker

`AshCompliance.Workers.EvidenceFreshness` runs
`AshCompliance.Ownership.Sweep` on a schedule you choose. Each `:unknown`
criterion raises a `Finding` with status `:unknown` under the subject
`evidence_freshness`. When the evidence is established again the finding is
resolved and its status stays `:unknown`; fresh evidence shows an owner and
recent artifacts, not compliance. The worker reports and never blocks: it
succeeds whatever it finds, and fails only when the sweep could not run.

These findings are written to the projection resource directly, not through the
event log, so a projector rebuild does not reproduce them; the next sweep does.

### Silencing

The only way to silence a criterion is a `PolicyOverride` waiver for rule id
`evidence-freshness:<criterion>` (`Freshness.rule_id/1`) with a named approver
an expiry no more than 90 days after its start, and a recorded requester who
is a different person from the approver (`PolicyOverride.requested_by`, checked
by the same separation-of-duties decision the operator processes use; the
create is refused otherwise). While it is in force no finding is raised and the result
carries `silenced_by`; the criterion is still `:unknown`. At the expiry it
stops silencing and the next sweep raises the finding again. An override with
no approver, no expiry, a longer window, or no distinct requester never silences.
