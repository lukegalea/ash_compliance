# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyOverride.ValidateOverride do
  @moduledoc false

  # Waiver requirements, enforced as validations so an unaccountable waiver
  # cannot exist: bounded time, a named approver, compensating controls, and
  # replacement rules for :replace overrides.

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    with :ok <- require_present(changeset),
         :ok <- require_waiver_bounds(changeset, kind),
         :ok <- require_compensating_controls(changeset, kind) do
      require_replacement(changeset, kind)
    end
  end

  defp require_present(changeset) do
    approver = Ash.Changeset.get_attribute(changeset, :approver)

    if approver in [nil, ""] do
      {:error, "an override requires a named approver"}
    else
      :ok
    end
  end

  defp require_waiver_bounds(changeset, :waive) do
    expires_at = Ash.Changeset.get_attribute(changeset, :expires_at)
    starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)

    cond do
      is_nil(expires_at) ->
        {:error, "a waiver requires expires_at — waivers are bounded time, never open-ended"}

      not is_nil(starts_at) and DateTime.compare(expires_at, starts_at) != :gt ->
        {:error, "a waiver's expires_at must be after its starts_at"}

      true ->
        :ok
    end
  end

  defp require_waiver_bounds(_changeset, _kind), do: :ok

  defp require_compensating_controls(changeset, :waive) do
    controls = Ash.Changeset.get_attribute(changeset, :compensating_controls) || []

    if Enum.empty?(Enum.reject(controls, &(&1 in [nil, ""]))) do
      {:error,
       "a waiver requires compensating_controls — a waived rule must be offset, not just ignored"}
    else
      :ok
    end
  end

  defp require_compensating_controls(_changeset, _kind), do: :ok

  defp require_replacement(changeset, :replace) do
    if blank?(Ash.Changeset.get_attribute(changeset, :replacement_rules_json)) do
      {:error,
       "a replacement requires replacement_rules_json — the serialized replacement rule set"}
    else
      :ok
    end
  end

  defp require_replacement(_changeset, _kind), do: :ok

  defp blank?(value), do: value in [nil, ""]
end
