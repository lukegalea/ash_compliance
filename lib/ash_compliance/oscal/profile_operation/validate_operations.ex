# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Oscal.ProfileOperation.ValidateOperations do
  @moduledoc """
  Create-action validation on `AshCompliance.Resources.ProfileRevision`:
  normalizes every declared tailoring operation (via
  `AshCompliance.Oscal.ProfileOperation.normalize/1`) and refuses the
  revision on the first bad one — unknown ops, missing targets, and the
  approval-bearing `replace`/`waive` operations (those belong in
  `AshCompliance.Resources.PolicyOverride`). The normalized operations
  replace the raw input, so stored revisions are canonical.

  This is the revision cluster's one custom validation, refactored to
  declare its temporal posture (the slice-4 audit item): it reads the
  `operations` attribute and force-sets its normalized form — no clock
  reads, no side effects, `as_of` untouched.

  Temporal-safe: pure input canonicalization; the refusal messages are
  byte-identical before and after the temporal swap.
  """

  use Ash.Resource.Validation

  @impl true
  def temporal_safe?(_opts), do: true

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
