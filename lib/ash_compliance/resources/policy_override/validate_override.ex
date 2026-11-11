# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyOverride.ValidateOverride do
  @moduledoc """
  Waiver requirements, enforced as validations so an unaccountable waiver
  cannot exist: bounded time, a named approver who is not the requester, compensating controls, and
  replacement rules for :replace overrides.

  Temporal-safe: reads arguments and attributes only — no clock, no side
  effects. (`expires_at`/`starts_at` are create ARGUMENTS since Phase 3 —
  the stored window is the period, declared through these arguments.)
  """

  use Ash.Resource.Validation

  alias AshCompliance.Resources.PolicyOverride.WaiverChain

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    with :ok <- require_present(changeset),
         :ok <- require_separation(changeset),
         :ok <- require_waiver_bounds(changeset, kind),
         :ok <- require_chain_within_limit(changeset, kind),
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

  # The requester may not approve their own override: the same decision the
  # operator processes ask, failing closed on anything but an explicit permit.
  defp require_separation(changeset) do
    requester = Ash.Changeset.get_attribute(changeset, :requested_by)
    approver = Ash.Changeset.get_attribute(changeset, :approver)

    verdict = AshCompliance.Processes.SeparationOfDuties.check(requester, approver, [])

    if AshCompliance.Processes.SeparationOfDuties.permit?(verdict) do
      :ok
    else
      {:error,
       "an override must be requested by one person and approved by another (#{verdict.reason})"}
    end
  end

  defp require_waiver_bounds(changeset, :waive) do
    expires_at = Ash.Changeset.get_argument(changeset, :expires_at)
    starts_at = effective_starts_at(changeset)

    cond do
      is_nil(expires_at) ->
        {:error, "a waiver requires expires_at — waivers are bounded time, never open-ended"}

      is_nil(starts_at) ->
        # No explicit start and no write instant to compare against (the
        # caller pinned neither); BoundWindow defaults the write to now and
        # a past expiry surfaces as the data layer's stale-write refusal.
        :ok

      DateTime.compare(expires_at, starts_at) != :gt ->
        {:error, "a waiver's expires_at must be after its starts_at"}

      true ->
        :ok
    end
  end

  defp require_waiver_bounds(_changeset, _kind), do: :ok

  # The limit applies to a chain of waivers, not to each row: a waiver starting within the
  # renewal gap of the previous one (same organization, rule and scope) continues its chain,
  # and the chain as a whole may not exceed the maximum. Fails closed when the history cannot
  # be read.
  defp require_chain_within_limit(changeset, :waive) do
    expires_at = Ash.Changeset.get_argument(changeset, :expires_at)
    starts_at = effective_starts_at(changeset)

    if match?(%DateTime{}, expires_at) and match?(%DateTime{}, starts_at) do
      key = %{
        organization_id: Ash.Changeset.get_attribute(changeset, :organization_id),
        rule_id: Ash.Changeset.get_attribute(changeset, :rule_id),
        scope_key:
          AshCompliance.Resources.PolicyOverride.Changes.DeriveScopeKey.scope_key(changeset)
      }

      case WaiverChain.start_of_chain(key, starts_at) do
        {:ok, chain_start} ->
          limit = AshCompliance.Ownership.Freshness.max_waiver_seconds()

          if DateTime.diff(expires_at, chain_start) <= limit,
            do: :ok,
            else:
              {:error,
               "waivers for one rule and scope may not be chained past #{div(limit, 86_400)} days: " <>
                 "let the waiver lapse for #{div(AshCompliance.Ownership.Freshness.renewal_gap_seconds(), 3600)} hours and approve it again"}

        {:error, _} ->
          {:error, "the waiver history could not be read, so the chain limit cannot be checked"}
      end
    else
      :ok
    end
  end

  defp require_chain_within_limit(_changeset, _kind), do: :ok

  # The period's lower bound: an explicit `starts_at` argument, else the
  # write's pinned instant (set by `Changes.BoundWindow` from the argument,
  # or by an explicit `as_of` on the write).
  defp effective_starts_at(changeset) do
    case Ash.Changeset.get_argument(changeset, :starts_at) do
      nil -> changeset.as_of
      starts_at -> starts_at
    end
  end

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
