<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# OSCAL

`ash_compliance` speaks a tolerant subset of OSCAL JSON at its boundary and
keeps a relational model inside. Catalogs and profiles go in and out;
assessment results go out (see below). Component definitions and assessment
plans are out.

## Import

```bash
mix ash_compliance.import_oscal baseline.json --type catalog
mix ash_compliance.import_oscal tailoring.json --type profile --org <uuid> --catalog <uuid>
```

or programmatically:

```elixir
{:ok, catalog} = AshCompliance.Oscal.import_catalog(document, organization_id: org_id)
{:ok, profile} = AshCompliance.Oscal.import_profile(document, organization_id: org_id)
```

### What is preserved

* **Identifiers** — the document `uuid` lands on the catalog/profile;
  control ids stay verbatim and stable.
* **Parameters** — control `params` are stored on the control revision.
* **Citations** — stored on the control revision.
* **Revision lineage** — an import records a `CatalogVersion` /
  `ProfileRevision` with a content hash, the document version and a source
  note.

### Re-importing a catalog

A catalog document whose `(organization_id, metadata.title)` matches an
existing catalog is a re-import, decided by content:

* **Same content as the catalog's latest version** — a no-op. The existing
  catalog is returned and nothing is written.
* **Changed content** — a new `CatalogVersion` on the same catalog. Each
  control is decided on its own: an unchanged control is skipped; a changed
  control under a new version string has its active revisions withdrawn at
  the import instant and its new revision opened at that same instant.
* **Refused** — changed content under a catalog `metadata.version` that
  already exists for the catalog, or changed control content under a
  version string the control already uses. A re-import must carry a new
  version (a control's version is its own `version`, else the document's
  `metadata.version`). Content identical to an earlier catalog version that
  is not the latest is also refused: only a match with the latest version
  is a no-op, and the catalog's content hashes are unique, so the import
  fails with the same "already exists with different content" error.

The reused-version-string refusal is checked before a control's
predecessors are withdrawn. A failure after the withdrawal, while creating
the successor revision (a validation error, say), is not: it can leave
that control withdrawn with no active revision.

The import is not one transaction. A failure partway leaves the controls
imported so far in place, each with its predecessors already withdrawn,
and the control being imported when it failed may be withdrawn with no
successor (see above).

`published_at:` declares the instant the whole import lands at (default:
now), so a historical document can be imported at its real publication
time. It sets the catalog version's period start, the new control
revisions' start and the withdrawal instant. `import_profile/2` accepts it
too. Profiles have no withdraw lifecycle: every profile import creates a new
profile and revision. The mix task has no flag for `published_at:`; call
`AshCompliance.Oscal` directly for that.

### How OSCAL profiles map to house operations

OSCAL profiles speak in `imports`, `set_parameters` and `alters`. The
importer derives house-shaped tailoring operations from them:

* `set_parameters` → `parameterize` operations (stored; the compiler refuses
  parameterization in v1 — precompute parameterized facts);
* `alters` with `adds` → `supplement` operations;
* `alters` with `removals` → `exclude` operations;
* a house `operations` list passes through normalization verbatim, so
  `refine` operations (and their severity/message patches) travel in the same
  document.

Approval-bearing operations (`replace`, `waive`) are refused at import with a
pointer to `PolicyOverride` — a profile cannot carry what only an approved,
accountable override may.

## Export

```bash
mix ash_compliance.export_oscal --type catalog --id <uuid> --to catalog.json
mix ash_compliance.export_oscal --type profile --id <uuid>
```

Export reconstructs the document from the relational model: document uuid,
metadata, controls with their active revision's statement/params/citations,
and (for profiles) the latest revision's stored operations.

## Assessment results

An auditor's package for one organization and one period is two calls:

```elixir
{:ok, sections} =
  AshCompliance.Ownership.Package.sections(org_id, from, to,
    controls_file: "path/to/controls.json",
    categories: [:security, :availability],
    extra_observations: [...],
    extra_findings: [...]
  )

document =
  AshCompliance.Oscal.AssessmentResults.build(sections, %{
    namespace: "urn:example:audit-package"
  })
```

`sections/4` composes what the compliance plane holds and writes nothing:
the criteria in scope with the control file's row for each, every artifact
collected in the period from the hot table and the evidence archive alike,
each re-checked against its hash, each criterion's freshness at the end of the
period with the waivers in force then, and the findings open at any time in
the period. Freshness is evaluated at the earlier of `to` and `generated_at`.

`build/2` turns the sections into an OSCAL 1.2.3 assessment-results document
with one result for the period:

* an observation for every artifact collected in the period, with the
  artifact's assessment method, and one for each criterion's freshness;
* a `not-satisfied` finding for every criterion whose freshness is unknown
  (reason `other`), and for every open finding that is not compliant (reason
  `fail` when noncompliant, `other` otherwise).

The document **never says `satisfied`**. The package answers owned,
evidenced or unknown; only an auditor attests. An evidenced criterion has
observations and no finding.

The organization, period and generation time come from the sections unless
`meta` overrides them. Every identifier is a version 5 UUID derived from what
it names, so the same inputs always give the same document. Facts OSCAL has no field for travel as
properties in `meta.namespace`.

### The host's part

Who may export, and for which organization, is decided by the host before it
calls `sections/4`. The control file is the host's. Anything the compliance
plane cannot observe itself (an audit-log verification, the review tasks of a
process engine) goes in as plain maps:

* `extra_observations`: `%{id:, title:, description:, methods:, collected:}`,
  with optional `props:` and `relevant_evidence:`;
* `extra_findings`: `%{id:, title:, description:, control_id:, reason:}`,
  where `reason` is `:fail` or `:other`, with optional `remarks:` and `props:`.

`:id` is the name the item's UUID is derived from. A malformed item, or a
finding with any other reason, raises `ArgumentError` rather than produce a
document that claims something it should not.

`AshCompliance.Oscal.AssessmentResults.validate/1` checks a document against
NIST's official schema, which ships with the package, licence and all, in
`priv/oscal/1.2.3/`. Validate the document you actually publish: `build/2`
checks the shape of your `extra_observations` and `extra_findings`, not every
rule OSCAL puts on their values (a property name must be a token, a time must
be a date-time), and the schema does.

```elixir
doc = AshCompliance.Oscal.AssessmentResults.build(sections, meta)
:ok = AshCompliance.Oscal.AssessmentResults.validate(doc)
```

It returns `:ok` or `{:error, errors}`, JSV's normalized error map. It needs
the optional `jsv` dependency, so add `{:jsv, "~> 0.26"}` to your deps (a
test-only dependency is enough to validate in your suite); without it,
`validate/1` raises saying so. The package's own suite validates every
document it builds with it.
