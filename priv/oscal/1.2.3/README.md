<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# OSCAL 1.2.3 assessment-results JSON schema (vendored)

`oscal_assessment-results_schema.json` is NIST's official JSON schema for the OSCAL
assessment-results model, release v1.2.3, copied unchanged from the release asset:

- source: https://github.com/usnistgov/OSCAL/releases/download/v1.2.3/oscal_assessment-results_schema.json
- sha-256: `4034e2032332dbf597e59e0646ec16c2c31df992962490371e91f47b219ff42c`
- licence: `LICENSE.md` beside it, copied from the OSCAL repository at the same tag. The
  work is in the public domain in the United States and dedicated to the public domain
  worldwide under CC0 1.0. NIST asks that it be acknowledged as the source, which this
  file does. `REUSE.toml` at the repository root records both files as CC0-1.0.

It ships in the Hex package. `AshCompliance.Oscal.AssessmentResults.validate/1` validates
a document against it with JSV (an optional dependency), and
`test/oscal_assessment_results_test.exs` validates every document
`AshCompliance.Oscal.AssessmentResults.build/2` produces and checks the file against the
pin above.

## How it is read

The schema is draft-07. Each definition repeats its own location as its `$id`
(`"$id": "#/definitions/<name>"`), which JSV refuses as an identifier.
`AssessmentResults` reads the file at compile time and removes an `$id` only where it
equals the definition's own location, which changes nothing it resolves to; any other
`$id` fails compilation. The file itself is never edited.

## Re-pinning

1. Download the schema and `LICENSE.md` of the new release into a new version directory.
2. Move `@oscal_version` in `AshCompliance.Oscal.AssessmentResults` (it names the
   directory the schema is read from) and the path and pin in the test.
3. Run the test, and read the release notes for model changes before accepting it.
