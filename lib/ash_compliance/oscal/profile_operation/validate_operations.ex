# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Oscal.ProfileOperation.ValidateOperations do
  @moduledoc false

  # Create-action validation on ProfileRevision: normalizes every declared
  # operation and refuses the revision on the first bad one. The normalized
  # operations replace the raw input, so stored revisions are canonical.

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    operations = Ash.Changeset.get_attribute(changeset, :operations) || []

    normalized =
      Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, acc} ->
        case AshCompliance.Oscal.ProfileOperation.normalize(operation) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    case normalized do
      {:ok, operations} ->
        Ash.Changeset.force_change_attribute(changeset, :operations, Enum.reverse(operations))
        :ok

      {:error, error} ->
        {:error, error}
    end
  end
end
