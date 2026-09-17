<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# OSCAL

`ash_compliance` speaks a tolerant subset of OSCAL JSON at its boundary and
keeps a relational model inside. v1 scope: catalogs and profiles only
(component definitions and assessment plans are out).

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
* **Revision lineage** — every import creates a `CatalogVersion` /
  `ProfileRevision` with a content hash, the document version and a source
  note. Re-importing identical content produces an identical hash; versions
  are unique per `(catalog, version)`.

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
