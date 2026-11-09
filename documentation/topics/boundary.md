# The boundary declaration

A declaration has two halves with one direction of dependency.

- **`AshCompliance.Boundary`** declares environments and the resources in them, and
  generates the files an infrastructure repository needs. It knows nothing about audits.
  The test for what belongs here: would a team with no audit still want it? If yes, it is
  production. See ADR 0064 in `ash_enterprise`.
- **`AshCompliance.Boundary.Controls`** declares which environments an audit covers and
  links criteria to the resources and evidence that carry them. It reads the production
  facts and never changes them.

Both generate deterministic JSON only: no HCL, no OSCAL, no stack.

## Production alone

A declaration with no controls uses the first extension on its own, through
`AshCompliance.Boundary.Production`, a Spark DSL whose only default extension it is:

```elixir
defmodule MyHost.Boundary do
  use AshCompliance.Boundary.Production

  boundary do
    name "my-host"
    output_dir "priv/boundary"
  end

  environments do
    environment :production do
      class :production
      zone "zone-a"
    end

    environment :preview do
      class :non_production
      data_ceiling :synthetic
    end
  end

  resources do
    resource :load_balancer do
      environment :production
      kind :managed
      type "lb"
      attributes %{"internal" => false}
    end

    resource :identity_provider do
      environment :production
      kind :data_source
    end
  end
end
```

It emits `boundary.auto.tfvars.json`, `infra.assertions.json` and `boundary.snapshot.json`.

## With controls

`use AshCompliance.Boundary.Declaration` includes both extensions. Add a `controls` section
to the module above:

```elixir
controls do
  audited_environments [:production]

  control "CC6.6" do
    resources [:load_balancer]
    evidence ["infra.verify:tls_listener"]
  end
end
```

It adds `control-map.json` and `controls.snapshot.json`. Changing only a control leaves the
three production files byte-identical.

## What it declares

- **Environments** are `:production`, or `:non_production` under a data ceiling
  (`:synthetic` or `:pseudonymised`). A non-production environment with no ceiling does not
  compile, and neither does a production one that declares one. A `zone` is a reference by
  id to a data-residency zone defined elsewhere. This extension defines no zone.
- **Resources** sit in one environment. A `:managed` resource is provisioned by the host and
  needs a `type`; its optional `attributes` are what an applied-state check should find. A
  `:data_source` is read, not provisioned.
- **`audited_environments`** names the production environments the audit covers. It must be
  non-empty when any control is declared, and each name must be a declared environment of
  class `:production`.
- **Controls** link a criterion to the resources that carry it and the evidence references
  that would prove it.

## What does not compile

Production: a non-production environment with no data ceiling; a production one with a
ceiling; a class other than `:production` or `:non_production`; a resource in an undeclared
environment; duplicate names; a managed resource with no type; a blank zone id.

Controls: `audited_environments` missing or empty while a control exists; an audited name
that is undeclared or not production; a control with no resource in an audited environment;
a control that names an undeclared resource; a control with no non-blank evidence reference;
a blank or duplicate criterion. A resource outside the audited environments never satisfies a
control.

The rules run as Spark transformers rather than verifiers. Spark reports a verifier error as
a compiler warning, which a host that does not compile with warnings as errors would ship.
Each half reports all its violations together.

## What is generated

Every file is sorted and independent of declaration order. Equal declarations produce equal
bytes.

| File | Half | Holds |
|---|---|---|
| `boundary.auto.tfvars.json` | production | Environments, managed resources, data sources and zones as variables |
| `infra.assertions.json` | production | What an applied-state check should find, one assertion per resource and data ceiling (schema `boundary.assertions/1`) |
| `boundary.snapshot.json` | production | The normalised environments and resources, so a changed declaration is visible as a diff (schema `boundary.snapshot/1`) |
| `control-map.json` | controls | Each criterion, its resources and its evidence references, in state `owned` |
| `controls.snapshot.json` | controls | The audited environments and normalised controls (schema `ash_compliance.boundary.controls-snapshot/1`) |

`owned` says the declaration names who carries a control. It never says the control
operates or has evidence. That is the evaluator's answer, from dated artifacts.

## Codegen

`mix ash.codegen` finds every declaration in the project and writes its files.
`mix ash.codegen --check` fails with `Ash.Error.Framework.PendingCodegen` when any file is
missing, empty, malformed or differs from what the declaration renders, on either half;
`--dry-run` prints the pending files. A missing file is pending, never current.

Codegen asks each extension the declaration uses for its files through
`AshCompliance.Boundary.GeneratedFiles`, so it needs to know no extension by name. A file
left on disk by an extension a declaration no longer uses is not noticed; delete it.

`--dev` and `--name` are accepted and ignored. `--boundary Module` and `--output-dir DIR`
are accepted by `AshCompliance.Boundary.codegen/1` when it is called directly. `mix ash.codegen`
passes every flag to every extension, and AshPostgres rejects these two, so use discovery there.

Commit the generated files. The check is the CI gate.
