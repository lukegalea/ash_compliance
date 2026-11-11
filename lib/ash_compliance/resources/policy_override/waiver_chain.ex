# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyOverride.WaiverChain do
  @moduledoc """
  Finds where a chain of waivers began.

  A waiver continues the chain of an earlier one for the same organization, rule and scope
  when it starts less than `Freshness.renewal_gap_seconds/0` after that one ended. The chain
  start is the earliest start in such a run. `ValidateOverride` uses it to hold the whole
  chain to `Freshness.max_waiver_seconds/0`, so back-to-back waivers cannot keep a criterion
  silenced without a lapse.

  Every read is an explicit point in time over the temporal resource, through Ash, so the
  module is temporal safe. History is followed back at most `@max_links` waivers; a longer
  history is reported as an error, which the caller treats as a refusal.
  """

  require Ash.Query

  alias AshCompliance.Ownership.Freshness
  alias AshCompliance.Resources.PolicyOverride

  @max_links 200

  @type key :: %{organization_id: term(), rule_id: term(), scope_key: String.t()}

  @spec start_of_chain(key(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def start_of_chain(key, %DateTime{} = starts_at),
    do: walk(key, starts_at, starts_at, @max_links)

  defp walk(_key, _from, _earliest, 0), do: {:error, :chain_too_long}

  defp walk(key, from, earliest, left) do
    gap = Freshness.renewal_gap_seconds()
    probes = [DateTime.add(from, -1, :microsecond), DateTime.add(from, -gap, :second)]

    with {:ok, found} <- predecessors(key, probes) do
      case Enum.max_by(found, & &1.starts_at, DateTime, fn -> nil end) do
        nil ->
          {:ok, earliest}

        %{starts_at: %DateTime{} = prev_start} ->
          if DateTime.compare(prev_start, earliest) == :lt,
            do: walk(key, prev_start, prev_start, left - 1),
            else: {:ok, earliest}

        _ ->
          {:error, :unreadable_period}
      end
    end
  end

  # The waivers in force at each probe instant: one just before the new window opens, and
  # one a renewal gap before it. Together they find a predecessor that ended inside the gap.
  defp predecessors(key, probes) do
    Enum.reduce_while(probes, {:ok, []}, fn at, {:ok, acc} ->
      case in_force_at(key, at) do
        {:ok, rows} -> {:cont, {:ok, rows ++ acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp in_force_at(%{organization_id: org, rule_id: rule, scope_key: scope}, at) do
    PolicyOverride
    |> Ash.Query.filter(
      organization_id == ^org and rule_id == ^rule and scope_key == ^scope and kind == :waive
    )
    |> Ash.Query.as_of(at)
    |> Ash.Query.load([:starts_at, :expires_at])
    |> Ash.read(authorize?: false)
  end
end
