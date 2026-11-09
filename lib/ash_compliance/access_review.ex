# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.AccessReview do
  @moduledoc """
  The effective-access review: open a campaign against several sources, record a
  decision for each person, close it, and leave an evidence artifact behind.

  ## The shape of a campaign

  `open/4` asks every source what it grants
  (`AshCompliance.AccessReview.Source`), merges the answers into one row per
  person and stores them with a record of what each source said. The campaign is
  `:open` only when every source answered with entries. A source that errored,
  raised, timed out, returned nothing or returned malformed entries makes the
  campaign `:incomplete`; the rows from the sources that did answer are kept so
  the failure can be investigated, but an incomplete campaign accepts no
  decisions and cannot be closed. A review of nothing never passes.

  `decide/6` records a decision. Decisions are append-only, sealed, and refuse a
  reviewer who is the person under review or is acting for them.

  `close/4` closes the campaign when every row is decided and nothing was
  altered, passes the sign-off through the separation decision, and then writes
  an evidence artifact for the criteria the `effective_access_review` template
  supports. The artifact says the review was run and signed off; it does not say
  the access was appropriate.
  """

  alias AshCompliance.AccessReview.Merge
  alias AshCompliance.Domain
  alias AshCompliance.Processes.Completion

  @template "effective_access_review"

  @type source :: module()

  @doc """
  Opens a campaign.

  `attrs` carries `:name`, `:period` and `:opened_by`. `sources` is a list of
  modules implementing `AshCompliance.AccessReview.Source`; an empty list, a
  repeated source id or a module that is not a source is an error and opens
  nothing.

  Options: `:as_of` (default now), `:source_options` (a map of source id to a
  map handed to that source), `:source_timeout` (milliseconds), `:actor`,
  `:authorize?` (default `false`).

  Returns `{:ok, campaign}`; check `campaign.status`.
  """
  @spec open(String.t(), map(), [source()], keyword()) :: {:ok, struct()} | {:error, term()}
  def open(organization_id, attrs, sources, opts \\ []) do
    with {:ok, pairs} <- identify(sources) do
      as_of = Keyword.get_lazy(opts, :as_of, &DateTime.utc_now/0)
      options = Keyword.get(opts, :source_options, %{})
      timeout = Keyword.get(opts, :source_timeout, 30_000)

      results =
        Map.new(pairs, fn {id, module} ->
          context = %{
            organization_id: organization_id,
            as_of: as_of,
            options: Map.get(options, id, %{})
          }

          {id, Merge.run_source(module, context, timeout: timeout)}
        end)

      rows =
        results
        |> Enum.filter(fn {_, result} -> result.status == :ok end)
        |> Enum.map(fn {id, result} -> {id, result.entries} end)
        |> Merge.merge()

      persist(organization_id, attrs, pairs, results, rows, as_of, opts)
    end
  end

  defp identify([]), do: {:error, :no_sources}

  defp identify(sources) when is_list(sources) do
    pairs =
      Enum.map(sources, fn module ->
        with true <- is_atom(module) and Code.ensure_loaded?(module),
             true <-
               function_exported?(module, :id, 0) and function_exported?(module, :entries, 1),
             id when is_binary(id) and id != "" <- module.id() do
          {id, module}
        else
          _ -> {:invalid, module}
        end
      end)

    ids = for {id, _} <- pairs, is_binary(id), do: id

    cond do
      (invalid = Enum.find(pairs, &match?({:invalid, _}, &1))) != nil ->
        {:error, {:invalid_source, elem(invalid, 1)}}

      ids != Enum.uniq(ids) ->
        {:error, :duplicate_source}

      true ->
        {:ok, pairs}
    end
  end

  defp identify(_), do: {:error, :no_sources}

  defp persist(organization_id, attrs, pairs, results, rows, as_of, opts) do
    ash_opts = [actor: opts[:actor], authorize?: Keyword.get(opts, :authorize?, false)]

    stored =
      Map.new(results, fn {id, r} ->
        {id, %{"status" => Atom.to_string(r.status), "count" => r.count, "detail" => r.detail}}
      end)

    Ash.transact(AshCompliance.Resources.AccessReviewCampaign, fn ->
      with {:ok, campaign} <-
             Domain.open_access_review_campaign(
               %{
                 organization_id: organization_id,
                 name: Map.get(attrs, :name),
                 period: Map.get(attrs, :period),
                 opened_by: Map.get(attrs, :opened_by),
                 opened_at: as_of,
                 source_ids: Enum.map(pairs, &elem(&1, 0)),
                 source_results: stored
               },
               ash_opts
             ),
           :ok <- add_rows(campaign, rows, ash_opts) do
        campaign
      end
    end)
  end

  defp add_rows(campaign, rows, ash_opts) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case Domain.add_access_review_row(
             %{
               organization_id: campaign.organization_id,
               campaign_id: campaign.id,
               person_key: row.person_key,
               sources: row.sources,
               entitlements: row.entitlements
             },
             ash_opts
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  Records a decision (`:keep` or `:revoke`) for a row.

  `delegators` is the list of people the reviewer is acting for; pass `[]` when
  they are acting for nobody.
  """
  @spec decide(String.t(), String.t(), :keep | :revoke, String.t() | nil, [String.t()], keyword()) ::
          {:ok, struct()} | {:error, term()}
  def decide(row_id, reviewer_id, decision, reason, delegators \\ [], opts \\ []) do
    with {:ok, row} <- Domain.get_access_review_row_by_id(row_id, authorize?: false) do
      Domain.record_access_review_decision(
        %{
          campaign_id: row.campaign_id,
          row_id: row.id,
          reviewer_id: reviewer_id,
          decision: decision,
          reason: reason,
          delegators: delegators
        },
        actor: opts[:actor],
        authorize?: Keyword.get(opts, :authorize?, false)
      )
    end
  end

  @doc """
  Closes a campaign and writes its evidence.

  The sign-off is `closed_by`; it must not be the person who opened the
  campaign or anyone listed in `delegators`. Options: `:collector` (required;
  the control file's `operating_process` reference), `:delegators` (default
  `[]`), `:now`, `:actor`, `:authorize?`.

  Returns `{:ok, %{campaign: campaign, artifacts: artifacts}}`. If the campaign
  closes but the evidence cannot be written, the error is
  `{:evidence_not_recorded, campaign, error}`: the campaign is closed and the
  control still reads as stale until the evidence is recorded.
  """
  @spec close(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close(campaign_id, closed_by, opts) do
    ash_opts = [actor: opts[:actor], authorize?: Keyword.get(opts, :authorize?, false)]

    with {:ok, campaign} <- Domain.get_access_review_campaign_by_id(campaign_id, ash_opts),
         {:ok, closed} <-
           Domain.close_access_review_campaign(
             campaign,
             %{closed_by: closed_by, delegators: Keyword.get(opts, :delegators, [])},
             ash_opts
           ) do
      complete(closed, opts)
    end
  end

  defp complete(campaign, opts) do
    attrs = %{
      instance_id: campaign.id,
      completed_by: campaign.closed_by,
      outcome: "completed",
      summary: Map.put(campaign.close_summary, "period", campaign.period)
    }

    case Completion.complete(campaign.organization_id, @template, attrs, opts) do
      {:ok, artifacts} -> {:ok, %{campaign: campaign, artifacts: artifacts}}
      {:error, error} -> {:error, {:evidence_not_recorded, campaign, error}}
    end
  end
end
