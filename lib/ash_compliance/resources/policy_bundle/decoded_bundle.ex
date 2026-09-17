# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyBundle.DecodedBundle do
  @moduledoc false

  # Calculation: the stored JSON decoded into an `AshRules.Ir.Bundle`, or an
  # error term when the stored JSON no longer decodes.

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:rules_json]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      case AshRules.Ir.decode(record.rules_json) do
        {:ok, bundle} -> {:ok, bundle}
        {:error, errors} -> {:error, List.wrap(errors)}
      end
    end)
  end
end
