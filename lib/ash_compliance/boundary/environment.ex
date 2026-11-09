# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Environment do
  @moduledoc "An environment a boundary declaration names: audited, or excluded under a data ceiling."

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
end
