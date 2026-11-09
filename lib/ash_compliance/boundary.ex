# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary do
  @moduledoc """
  A Spark extension that declares an audit boundary and generates the files
  that carry it into infrastructure code and an auditor's view.

  A declaration has four parts.

    * `boundary` - a `name`, and the `output_dir` the files are written to
      (default `priv/boundary`).
    * `environments` - each `environment` is `:audited`, or `:excluded` under
      a `data_ceiling` (`:synthetic` or `:pseudonymised`). An environment may
      name a `zone` by id. The zone is only a reference: this extension
      defines no zone and checks nothing about it beyond its being a
      non-blank id.
    * `resources` - each `resource` sits in one environment and is `:managed`
      (the host provisions it, so it has a `type` and optional expected
      `attributes`) or a `:data_source` (read, not provisioned).
    * `controls` - each `control` links a criterion to the `resources` that
      carry it and the `evidence` references that would prove it.

  A declaration that does not compile is refused: a control with no resource
  in an audited environment, a control or resource that names something
  undeclared, an excluded environment with no data ceiling, an audited one
  with a ceiling, duplicate names, a managed resource with no type, or a
  control with no evidence reference. A resource in an excluded environment
  never satisfies a control.

  ## Generated files

  Deterministic JSON, sorted and independent of declaration order:

    * `control-map.json` - each criterion, its resources and its evidence
      references, in state `owned`.
    * `boundary.auto.tfvars.json` - environments, managed resources, data
      sources and zones, as Terraform-style variables.
    * `infra.assertions.json` - what an applied-state check should find.
    * `boundary.snapshot.json` - the normalised declaration, so a changed
      declaration shows up as a diff.

  `owned` says a declaration names who carries the control. It does not say
  the control operates or has evidence; that is for the evidence evaluator.

  ## Codegen

  `mix ash.codegen` finds every declaration in the project and writes its
  files. `mix ash.codegen --check` fails when any file is missing or stale,
  and `--dry-run` prints what would change. Calling `codegen/1` directly also
  takes `--boundary Module` (repeatable, in place of discovery) and
  `--output-dir DIR` (with exactly one `--boundary`); `mix ash.codegen` cannot
  pass them, because AshPostgres rejects unknown flags.
  """

  alias AshCompliance.Boundary.{Codegen, Control, Environment, Resource}

  @boundary %Spark.Dsl.Section{
    name: :boundary,
    describe: "Names the boundary and says where its files are written.",
    schema: [
      name: [type: :string, required: true, doc: "The boundary's name, carried into every file."],
      output_dir: [
        type: :string,
        default: "priv/boundary",
        doc: "Directory the files are written to, relative to the project root."
      ]
    ]
  }

  @environment %Spark.Dsl.Entity{
    name: :environment,
    describe: "An environment: audited, or excluded under a data ceiling.",
    target: Environment,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      class: [type: {:one_of, [:audited, :excluded]}, required: true],
      data_ceiling: [
        type: {:one_of, [:synthetic, :pseudonymised]},
        doc: "The most sensitive data an excluded environment may hold. Required when excluded."
      ],
      zone: [type: :string, doc: "A data-residency zone id, held by reference."],
      description: [type: :string]
    ]
  }

  @resource %Spark.Dsl.Entity{
    name: :resource,
    describe: "A resource in one environment.",
    target: Resource,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      environment: [type: :atom, required: true],
      kind: [type: {:one_of, [:managed, :data_source]}, required: true],
      type: [type: :string, doc: "The provider resource type. Required when managed."],
      attributes: [
        type: {:map, :string, {:or, [:string, :boolean, :integer]}},
        default: %{},
        doc: "Expected attributes, string keys, string, boolean or integer values."
      ],
      description: [type: :string]
    ]
  }

  @control %Spark.Dsl.Entity{
    name: :control,
    describe: "Links a criterion to its resources and evidence references.",
    target: Control,
    args: [:criterion],
    identifier: :criterion,
    schema: [
      criterion: [type: :string, required: true],
      resources: [type: {:list, :atom}, required: true],
      evidence: [type: {:list, :string}, required: true]
    ]
  }

  @environments %Spark.Dsl.Section{name: :environments, entities: [@environment]}
  @resources %Spark.Dsl.Section{name: :resources, entities: [@resource]}
  @controls %Spark.Dsl.Section{name: :controls, entities: [@control]}

  use Spark.Dsl.Extension,
    sections: [@boundary, @environments, @resources, @controls],
    transformers: [AshCompliance.Boundary.Transformers.EnforceRules]

  @doc false
  def name, do: "AshCompliance.Boundary"

  @doc """
  The `mix ash.codegen` hook. Raises `Ash.Error.Framework.PendingCodegen`
  under `--check` when a generated file is missing or differs.
  """
  @spec codegen([String.t()]) :: :ok
  def codegen(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [
          check: :boolean,
          dry_run: :boolean,
          dev: :boolean,
          name: :string,
          boundary: [:string, :keep],
          output_dir: :string
        ]
      )

    modules =
      case Keyword.get_values(opts, :boundary) do
        [] -> Codegen.discover()
        names -> Enum.map(names, &Module.concat([&1]))
      end

    if opts[:output_dir] && length(modules) != 1 do
      Mix.raise("--output-dir needs exactly one boundary")
    end

    run_opts = Keyword.take(opts, [:check, :dry_run, :output_dir])

    pending = Enum.flat_map(modules, &pending_or_raise(&1, run_opts))

    cond do
      opts[:check] && pending != [] ->
        raise Ash.Error.Framework.PendingCodegen, diff: pending, explain: false

      opts[:check] || opts[:dry_run] ->
        :ok

      true ->
        Enum.each(pending, &Mix.shell().info("* wrote #{&1}"))
        :ok
    end
  end

  defp pending_or_raise(module, run_opts) do
    unless AshCompliance.Boundary.Info.declaration?(module) do
      Mix.raise("#{inspect(module)} is not a boundary declaration")
    end

    Codegen.run(module, run_opts)
  end
end
