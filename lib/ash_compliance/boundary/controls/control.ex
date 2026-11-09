# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Controls.Control do
  @moduledoc "A link from one criterion to the resources that carry it and the evidence references that would prove it."

  defstruct [:criterion, :__spark_metadata__, :__identifier__, resources: [], evidence: []]

  @type t :: %__MODULE__{}
end
