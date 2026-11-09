# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Transformers.EnforceRules do
  @moduledoc """
  Fails the compile of a declaration that breaks `AshCompliance.Boundary.Rules`.

  Spark reports an error from an `@after_verify` verifier as a compiler
  warning, which a host that does not compile with warnings as errors would
  ship. A transformer error raises, so the rules run here.
  """

  use Spark.Dsl.Transformer

  alias AshCompliance.Boundary.Rules
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    decl = %{
      name: Transformer.get_option(dsl_state, [:boundary], :name),
      environments: Transformer.get_entities(dsl_state, [:environments]),
      resources: Transformer.get_entities(dsl_state, [:resources])
    }

    case Rules.violations(decl) do
      [] ->
        {:ok, dsl_state}

      violations ->
        {:error,
         Spark.Error.DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:boundary],
           message: "invalid boundary declaration:\n  - " <> Enum.join(violations, "\n  - ")
         )}
    end
  end
end
