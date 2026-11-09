# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Sweep do
  @moduledoc """
  Reads the control file, the evidence and the overrides for an organization,
  evaluates freshness, and raises a `Finding` for every criterion that is
  unknown and not silenced.

  A sweep never blocks anything. It reports: a stale control becomes a
  finding with status `:unknown`, and the caller (typically
  `AshCompliance.Workers.EvidenceFreshness`) carries on.

  ## What the finding means

  The finding is filed at the grain
  `{organization, criterion, "evidence_freshness", "control"}`, so it is
  separate from any finding a projector derives for the same criterion. Its
  status is `:unknown` while the evidence is not established. When the
  evidence is established again the same finding is *resolved* (`resolved_at`
  set) and its status stays `:unknown`: fresh evidence shows the control has
  an owner and recent artifacts, it does not make the finding say
  "compliant".

  These findings are written straight to the projection resource, not
  through the event log, so a projector rebuild does not reproduce them. The
  next sweep restores them.

  ## Silencing

  The only way to silence a criterion is a `PolicyOverride` waiver for
  `AshCompliance.Ownership.Freshness.rule_id/1` with an approver and an
  expiry. While it is in force the criterion's result carries `silenced_by`
  and no finding is raised. At the expiry it stops silencing, and the next
  sweep raises the finding again. A silenced criterion is still `:unknown` in
  the results.
  """

  alias AshCompliance.Domain
  alias AshCompliance.Ownership.{ControlFile, Criteria, Freshness}

  @doc """
  Runs a sweep for `organization_id`.

  Options: `:controls_file` (required), `:categories` (default `[:security]`),
  `:now`, `:actor`, `:authorize?` (default `false`; sweeps are trusted
  machinery).

  Returns `{:ok, results}` with one result per in-scope criterion.
  """
  @spec run(String.t(), keyword()) :: {:ok, [Freshness.result()]} | {:error, term()}
  def run(organization_id, opts) do
    path = Keyword.fetch!(opts, :controls_file)
    categories = Keyword.get(opts, :categories, [:security])
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ash_opts = [actor: opts[:actor], authorize?: Keyword.get(opts, :authorize?, false)]

    with {:ok, artifacts} <- load_artifacts(organization_id, categories, ash_opts),
         {:ok, overrides} <-
           Domain.valid_policy_overrides(
             organization_id,
             now,
             [load: [:starts_at, :expires_at]] ++ ash_opts
           ) do
      results =
        path
        |> ControlFile.load()
        |> Freshness.evaluate_all(artifacts,
          categories: categories,
          now: now,
          overrides: overrides
        )

      with :ok <- file_findings(organization_id, results, now, ash_opts), do: {:ok, results}
    end
  end

  defp load_artifacts(organization_id, categories, ash_opts) do
    categories
    |> Criteria.in_categories()
    |> Enum.reduce_while({:ok, %{}}, fn %{id: id}, {:ok, acc} ->
      case Domain.evidence_for_control(organization_id, id, ash_opts) do
        {:ok, artifacts} -> {:cont, {:ok, Map.put(acc, id, artifacts)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp file_findings(organization_id, results, now, ash_opts) do
    existing = existing_findings(organization_id, ash_opts)

    Enum.reduce_while(results, :ok, fn result, :ok ->
      case file(organization_id, result, existing, now, ash_opts) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp existing_findings(organization_id, ash_opts) do
    case Domain.findings_for_organization(organization_id, ash_opts) do
      {:ok, findings} ->
        for %{subject_type: "evidence_freshness", subject_id: "control"} = finding <- findings,
            into: %{},
            do: {finding.control_id, finding}

      {:error, _} ->
        %{}
    end
  end

  # Silenced: leave the finding as it is. Silencing never raises and never
  # clears.
  defp file(_org, %{state: :unknown, silenced_by: %{}}, _existing, _now, _ash_opts), do: :ok

  defp file(org, %{state: :unknown} = result, existing, now, ash_opts) do
    first_seen =
      if existing[result.criterion] && existing[result.criterion].first_seen_at,
        do: [],
        else: [{:set, :first_seen_at, now}]

    ops =
      first_seen ++
        [
          {:set, :status, :unknown},
          {:set, :gap, "evidence_freshness"},
          {:set, :last_seen_at, now},
          {:set, :resolved_at, nil},
          {:set, :explanation, "#{result.reason}: #{result.detail}"}
        ]

    apply_ops(org, result.criterion, ops, ash_opts)
  end

  # Established again: resolve a finding that is open; never create one.
  defp file(org, result, existing, now, ash_opts) do
    case existing[result.criterion] do
      %{resolved_at: nil} ->
        ops = [
          {:set, :resolved_at, now},
          {:set, :last_seen_at, now},
          {:set, :explanation, "#{result.state}: #{result.detail}"}
        ]

        apply_ops(org, result.criterion, ops, ash_opts)

      _ ->
        :ok
    end
  end

  defp apply_ops(org, criterion, ops, ash_opts) do
    grain = %{
      organization_id: org,
      control_id: criterion,
      subject_type: Freshness.subject_type(),
      subject_id: Freshness.subject_id()
    }

    with {:ok, row} <- Domain.upsert_finding_grain(grain, ash_opts),
         {:ok, _} <- Domain.apply_finding_ops(row, ops, ash_opts) do
      :ok
    end
  end
end
