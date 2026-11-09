# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Controls do
  @moduledoc """
  A Spark extension that links criteria to the production facts that carry
  them, and generates an auditor's view.

  It reads the environments and resources declared by `AshCompliance.Boundary`
  and adds a `controls` section:

      controls do
        audited_environments [:production]

        control "CC6.6" do
          resources [:load_balancer]
          evidence ["infra.verify:tls_listener"]
        end
      end

    * `audited_environments` - the names of the environments the audit covers.
      Each must be a declared environment of class `:production`. It must be
      non-empty when any control is declared.
    * `control` - links a `criterion` to the `resources` that carry it and the
      `evidence` references that would prove it.

  A declaration is refused when `audited_environments` is missing, empty or
  names an environment that is undeclared or non-production; when a control
  has no resource in an audited environment, names an undeclared resource,
  has a blank criterion, or has no non-blank evidence reference; or when a
  criterion is declared twice.

  ## Generated files

    * `control-map.json` - each criterion, its resources and its evidence
      references, in state `owned`.
    * `controls.snapshot.json` - the audited environments and the normalised
      controls, so a changed link shows up as a diff.

  `owned` says a declaration names who carries the control. It does not say
  the control operates or has evidence; that is for the evidence evaluator.
  """

  alias AshCompliance.Boundary.Controls.{Control, Render}

  @behaviour AshCompliance.Boundary.GeneratedFiles

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

  @controls %Spark.Dsl.Section{
    name: :controls,
    describe: "The controls, and the environments the audit covers.",
    schema: [
      audited_environments: [
        type: {:list, :atom},
        doc: "Names of the production environments the audit covers."
      ]
    ],
    entities: [@control]
  }

  use Spark.Dsl.Extension,
    sections: [@controls],
    transformers: [AshCompliance.Boundary.Controls.Transformers.EnforceRules]

  @doc false
  def name, do: "AshCompliance.Boundary.Controls"

  @impl AshCompliance.Boundary.GeneratedFiles
  def generated_files(module) do
    module |> AshCompliance.Boundary.Controls.Info.declaration() |> Render.files()
  end
end
