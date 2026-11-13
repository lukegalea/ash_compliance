# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Package do
  @moduledoc """
  The compliance plane's part of an audit package: what an auditor is handed for one
  organization and one period. It composes what exists and writes nothing.

  `sections/4` returns:

    * **controls** - the Trust Services Criteria in the audit's categories
      (`AshCompliance.Ownership.Criteria`) and the control file's row for each
      (`AshCompliance.Ownership.ControlFile`), with the file's SHA-256;
    * **evidence** - every artifact collected in the period, hot or archived
      (`AshCompliance.Ownership.Evidence.for_control/3`), each re-checked against its
      hash, plus the newest artifact from each collector before the period; and each
      criterion's freshness at the end of the period, evaluated by
      `AshCompliance.Ownership.Freshness` over the artifacts collected by then and the
      waivers in force then;
    * **findings** - the compliance findings open at any time in the period;
    * **extra_observations** and **extra_findings** - the host's own, passed through
      for `AshCompliance.Oscal.AssessmentResults.build/2`.

  `AshCompliance.Oscal.AssessmentResults.build/2` turns the sections into an OSCAL
  assessment-results document.

  ## What stays the host's

  Who may export, and for which organization, is the host's: call this only after the
  host's own check. The control file is the host's (`:controls_file`), and so is any
  observation the compliance plane cannot make (an audit-log verification, the review
  tasks of a process engine), which the host passes as `:extra_observations` and
  `:extra_findings` (see `AshCompliance.Oscal.AssessmentResults` for their shape).
  """

  alias AshCompliance.Domain
  alias AshCompliance.Ownership.{ControlFile, Criteria, Evidence, Freshness}

  # Evidence content is carried inline when it is text and small; anything else is
  # carried by its hash, which is what pins its identity.
  @inline_limit 64 * 1024

  @doc """
  The sections for `organization_id` over `[from, to)`.

  Options:

    * `:controls_file` - **required**. The path of the host's control file.
    * `:categories` - the criteria categories in scope. Default `[:security]`.
    * `:extra_observations`, `:extra_findings` - lists of plain maps, carried into the
      sections unchanged. Default `[]`.
    * `:generated_at` - the export time. Default now. Freshness is evaluated at the
      earlier of `to` and this.
    * `:archive` - the evidence archive read beside the hot table. Default the
      `:evidence_archive` setting.
    * `:actor`, `:authorize?` - for every read. Default `authorize?: false`: the host
      checks who may export before it calls this.

  Returns `{:ok, sections}`, `{:error, :invalid_period}` when `from` is not before
  `to`, or the error of a read that failed.
  """
  @spec sections(String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sections(organization_id, %DateTime{} = from, %DateTime{} = to, opts) do
    if DateTime.compare(from, to) == :lt do
      build(organization_id, from, to, opts)
    else
      {:error, :invalid_period}
    end
  end

  defp build(organization_id, from, to, opts) do
    path = Keyword.fetch!(opts, :controls_file)
    categories = Keyword.get(opts, :categories, [:security])
    generated_at = Keyword.get_lazy(opts, :generated_at, &DateTime.utc_now/0)
    as_of = Enum.min([to, generated_at], DateTime)
    read_opts = Keyword.take(opts, [:actor, :authorize?, :archive])
    ash_opts = [actor: opts[:actor], authorize?: Keyword.get(opts, :authorize?, false)]

    criteria = Criteria.in_categories(categories)
    loaded = ControlFile.load(path)
    period = %{from: from, to: to, as_of: as_of}

    with {:ok, artifacts} <- artifacts(organization_id, criteria, read_opts),
         {:ok, overrides} <-
           Domain.valid_policy_overrides(
             organization_id,
             as_of,
             [load: [:starts_at, :expires_at]] ++ ash_opts
           ),
         {:ok, findings} <- Domain.findings_for_organization(organization_id, ash_opts) do
      known_by_end =
        Map.new(artifacts, fn {id, list} -> {id, collected_before(list, as_of)} end)

      freshness =
        Freshness.evaluate_all(loaded, known_by_end,
          categories: categories,
          now: as_of,
          overrides: overrides
        )

      {:ok,
       %{
         organization_id: organization_id,
         period: period,
         generated_at: generated_at,
         controls: controls(criteria, categories, path, loaded),
         evidence: evidence(criteria, freshness, artifacts, period),
         findings: findings(findings, period),
         extra_observations: Keyword.get(opts, :extra_observations, []),
         extra_findings: Keyword.get(opts, :extra_findings, [])
       }}
    end
  end

  # --- criteria --------------------------------------------------------------

  defp controls(criteria, categories, path, loaded) do
    rows =
      case loaded do
        {:ok, %{rows: rows}} -> Enum.filter(rows, &is_map/1)
        {:error, _} -> []
      end

    %{
      "framework" => "SOC 2 Trust Services Criteria (2017)",
      "categories" => Enum.map(categories, &to_string/1),
      "control_file" => control_file(path, loaded),
      "criteria" =>
        Enum.map(criteria, fn criterion ->
          %{
            "id" => criterion.id,
            "category" => to_string(criterion.category),
            "title" => criterion.title,
            "row" => Enum.find(rows, &(&1["id"] == criterion.id))
          }
        end)
    }
  end

  defp control_file(path, {:ok, %{document: document}}) do
    %{
      "path" => path,
      "loaded" => true,
      "sha256" => document |> Jason.encode!() |> Evidence.sha256(),
      "frameworks" => document["frameworks"]
    }
  end

  defp control_file(path, {:error, error}) do
    %{"path" => path, "loaded" => false, "error" => ControlFile.describe_error(error)}
  end

  # --- evidence --------------------------------------------------------------

  defp artifacts(organization_id, criteria, read_opts) do
    Enum.reduce_while(criteria, {:ok, %{}}, fn %{id: id}, {:ok, acc} ->
      case Evidence.for_control(organization_id, id, read_opts) do
        {:ok, list} -> {:cont, {:ok, Map.put(acc, id, Enum.map(list, &artifact/1))}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp artifact(row) do
    %{
      id: row.id,
      control_id: row.control_id,
      collector: row.collector,
      method: to_string(row.method),
      media_type: row.media_type,
      collected_at: row.collected_at,
      hash: row.hash,
      content: row.content,
      subject_type: row.subject_type,
      subject_id: row.subject_id,
      retention_class: row.retention_class,
      chain_of_custody: row.chain_of_custody || [],
      location: to_string(Evidence.location(row))
    }
  end

  defp collected_before(artifacts, at),
    do: Enum.filter(artifacts, &(DateTime.compare(&1.collected_at, at) == :lt))

  defp evidence(criteria, freshness, artifacts, period) do
    by_id = Map.new(freshness, &{&1.criterion, &1})

    %{
      "freshness_as_of" => iso(period.as_of),
      "criteria" =>
        Enum.map(criteria, fn criterion ->
          list = Map.get(artifacts, criterion.id, [])

          %{
            "id" => criterion.id,
            "freshness" => freshness_json(Map.get(by_id, criterion.id)),
            "artifacts" => list |> reported(period) |> Enum.map(&artifact_json(&1, period))
          }
        end)
    }
  end

  # The artifacts collected in the period, and before it the newest one from each
  # collector: what an annual control's freshness at the start of the period rests on.
  defp reported(artifacts, %{from: from, to: to}) do
    {before, rest} = Enum.split_with(artifacts, &(DateTime.compare(&1.collected_at, from) == :lt))
    inside = Enum.filter(rest, &(DateTime.compare(&1.collected_at, to) == :lt))

    basis =
      before
      |> Enum.group_by(& &1.collector)
      |> Enum.map(fn {_collector, list} -> List.last(list) end)

    Enum.sort_by(basis ++ inside, & &1.collected_at, DateTime)
  end

  defp artifact_json(artifact, %{from: from}) do
    {content, omitted} = inline(artifact)

    %{
      "id" => artifact.id,
      "control_id" => artifact.control_id,
      "collector" => artifact.collector,
      "method" => artifact.method,
      "media_type" => artifact.media_type,
      "collected_at" => iso(artifact.collected_at),
      "in_period" => DateTime.compare(artifact.collected_at, from) != :lt,
      "sha256" => artifact.hash,
      "integrity" => integrity(artifact),
      "location" => artifact.location,
      "subject_type" => artifact.subject_type,
      "subject_id" => artifact.subject_id,
      "retention_class" => artifact.retention_class,
      "chain_of_custody" => artifact.chain_of_custody,
      "content" => content,
      "content_omitted" => omitted
    }
  end

  @doc """
  An artifact's integrity as the package reports it, by `Evidence.verify/1`'s rule over a
  hot or archived row alike: `"verified"` only when the stored bytes are present and hash
  to the row's hash, else `"hash_mismatch"` or `"no_content"`.
  """
  @spec integrity(map()) :: String.t()
  def integrity(artifact) do
    case Evidence.verify(artifact) do
      :ok -> "verified"
      {:error, reason} -> to_string(reason)
    end
  end

  defp inline(%{content: content, media_type: type}) when is_binary(content) do
    cond do
      byte_size(content) > @inline_limit -> {nil, "larger than #{@inline_limit} bytes"}
      not text?(type) -> {nil, "not text (#{type})"}
      not String.valid?(content) -> {nil, "not valid UTF-8"}
      true -> {content, nil}
    end
  end

  defp inline(_artifact), do: {nil, "no content stored"}

  defp text?(type),
    do: String.starts_with?(type, "text/") or type in ["application/json", "application/xml"]

  defp freshness_json(nil), do: nil

  defp freshness_json(result) do
    %{
      "state" => to_string(result.state),
      "reason" => result.reason && to_string(result.reason),
      "detail" => result.detail,
      "sources" => result.sources,
      "latest_at" => result.latest_at && iso(result.latest_at),
      "silenced_by" => waiver(result.silenced_by)
    }
  end

  defp waiver(nil), do: nil

  defp waiver(by) do
    %{
      "approver" => by[:approver] && to_string(by[:approver]),
      "expires_at" => by[:expires_at] && iso(by[:expires_at]),
      "reason" => by[:reason]
    }
  end

  # --- findings --------------------------------------------------------------

  defp findings(all, %{from: from, to: to}) do
    open_in_period =
      all
      |> Enum.filter(fn finding ->
        seen = finding.first_seen_at || finding.inserted_at

        DateTime.compare(seen, to) == :lt and
          (is_nil(finding.resolved_at) or DateTime.compare(finding.resolved_at, from) != :lt)
      end)
      |> Enum.sort_by(&{&1.control_id, &1.subject_type, &1.subject_id})

    %{
      "note" =>
        "A finding is the projection's current state, read at export time; " <>
          "those open at any time in the period are listed.",
      "findings" =>
        Enum.map(open_in_period, fn finding ->
          %{
            "id" => finding.id,
            "control_id" => finding.control_id,
            "subject_type" => finding.subject_type,
            "subject_id" => finding.subject_id,
            "status" => to_string(finding.status),
            "severity" => finding.severity && to_string(finding.severity),
            "gap" => finding.gap,
            "breach_count" => finding.breach_count,
            "first_seen_at" => finding.first_seen_at && iso(finding.first_seen_at),
            "last_seen_at" => finding.last_seen_at && iso(finding.last_seen_at),
            "resolved_at" => finding.resolved_at && iso(finding.resolved_at),
            "explanation" => finding.explanation,
            "bundle_hash" => finding.bundle_hash,
            "rule_ids" => finding.rule_ids
          }
        end)
    }
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
