# The boundary declaration

`AshCompliance.Boundary` is a Spark extension for declaring an audit boundary once and
generating, from that one declaration, the files an infrastructure repository and an
auditor both need. It generates deterministic JSON only: no HCL, no OSCAL, no stack.

```elixir
defmodule MyHost.Boundary do
  use AshCompliance.Boundary.Declaration

  boundary do
    name "my-host"
    output_dir "priv/boundary"
  end

  environments do
    environment :production do
      class :audited
      zone "zone-a"
    end

    environment :preview do
      class :excluded
      data_ceiling :synthetic
    end
  end

  resources do
    resource :load_balancer do
      environment :production
      kind :managed
      type "aws_lb"
      attributes %{"internal" => false}
    end

    resource :identity_provider do
      environment :production
      kind :data_source
    end
  end

  controls do
    control "CC6.6" do
      resources [:load_balancer]
      evidence ["infra.verify:tls_listener"]
    end
  end
end
```

## What it declares

- **Environments** are `:audited`, or `:excluded` under a data ceiling (`:synthetic` or
  `:pseudonymised`). An excluded environment with no ceiling does not compile, and neither
  does an audited one that declares one. A `zone` is a reference by id to a data-residency
  zone defined elsewhere. This extension defines no zone.
- **Resources** sit in one environment. A `:managed` resource is provisioned by the host and
  needs a `type`; its optional `attributes` are what an applied-state check should find. A
  `:data_source` is read, not provisioned.
- **Controls** link a criterion to the resources that carry it and the evidence references
  that would prove it.

## What does not compile

A control with no resource in an audited environment; a control that names an undeclared
resource; a resource in an undeclared environment; an excluded environment with no data
ceiling; duplicate names; a managed resource with no type; a control with no non-blank
evidence reference. A resource in an excluded environment never satisfies a control.

The rules run as a Spark transformer rather than a verifier. Spark reports a verifier error
as a compiler warning, which a host that does not compile with warnings as errors would
ship. All violations are reported together.

## What is generated

Every file is sorted and independent of declaration order. Equal declarations produce equal
bytes.

| File | Holds |
|---|---|
| `control-map.json` | Each criterion, its resources and its evidence references, in state `owned` |
| `boundary.auto.tfvars.json` | Environments, managed resources, data sources and zones as variables |
| `infra.assertions.json` | What an applied-state check should find, one assertion per resource and data ceiling |
| `boundary.snapshot.json` | The normalised declaration, so a changed declaration is visible as a diff |

`owned` says the declaration names who carries a control. It never says the control
operates or has evidence. That is the evaluator's answer, from dated artifacts.

## Codegen

`mix ash.codegen` finds every declaration in the project and writes its files.
`mix ash.codegen --check` fails with `Ash.Error.Framework.PendingCodegen` when any file is
missing, empty, malformed or differs from what the declaration renders; `--dry-run` prints
the pending files. A missing file is pending, never current.

`--dev` and `--name` are accepted and ignored. `--boundary Module` and `--output-dir DIR`
are accepted by `AshCompliance.Boundary.codegen/1` when it is called directly. `mix ash.codegen`
passes every flag to every extension, and AshPostgres rejects these two, so use discovery there.

Commit the generated files. The check is the CI gate.
