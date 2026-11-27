# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Environment do
  @moduledoc "An environment a declaration names: production, or non-production under a data ceiling."

  defstruct [
    :name,
    :class,
    :data_ceiling,
    :zone,
    :description,
    :__spark_metadata__,
    :__identifier__
  ]

  @type t :: %__MODULE__{}

  @classes [:production, :non_production]

  @typedoc "The class of an environment."
  @type class :: :production | :non_production

  @doc """
  The classes an environment may be: `:production`, or `:non_production` under a data
  ceiling.
  """
  @spec classes() :: [class()]
  def classes, do: @classes
end
