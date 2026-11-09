# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Resource do
  @moduledoc "A resource a boundary declaration names: one the host manages, or a data source it only reads."

  defstruct [
    :name,
    :environment,
    :kind,
    :type,
    :description,
    :__spark_metadata__,
    :__identifier__,
    attributes: %{}
  ]

  @type t :: %__MODULE__{}
end
