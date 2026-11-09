# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Controls.Transformers.EnforceRules do
  @moduledoc """
  Fails the compile of a declaration that breaks
  `AshCompliance.Boundary.Controls.Rules`.

  Like the production rules, it runs as a transformer because Spark reports a
  verifier error as a compiler warning.
  """

  use Spark.Dsl.Transformer

  alias AshCompliance.Boundary.Controls.Rules
  alias Spark.Dsl.Transformer

  # The controls read the production facts, so those are checked first and a
  # broken environment is reported before a control that depends on it.
  @impl true
  def after?(AshCompliance.Boundary.Transformers.EnforceRules), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    decl = %{
      environments: Transformer.get_entities(dsl_state, [:environments]),
      resources: Transformer.get_entities(dsl_state, [:resources]),
      controls: Transformer.get_entities(dsl_state, [:controls]),
      audited_environments: Transformer.get_option(dsl_state, [:controls], :audited_environments)
    }

    case Rules.violations(decl) do
      [] ->
        {:ok, dsl_state}

      violations ->
        {:error,
         Spark.Error.DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:controls],
           message: "invalid controls:\n  - " <> Enum.join(violations, "\n  - ")
         )}
    end
  end
end
