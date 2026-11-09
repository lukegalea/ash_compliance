# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Freshness do
  @moduledoc """
  Pure evaluation of whether each criterion's evidence is current.

  The outcome is one of four states, and none of them says "compliant":

    * `:evidenced` - every source the row declares has a well-formed artifact
      inside the frequency window
    * `:owned` - a `PLATFORM-ENFORCED` row with no evidence source: an owner
      and a test, nothing to age
    * `:not_applicable` - declared out of scope, with a rationale
    * `:unknown` - anything else

  `:unknown` is the default for everything the evaluator cannot positively
  establish: a missing file, a malformed file, a missing row, an unknown class
  or frequency, no owner, no artifact, an artifact that is stale, future-dated
  or malformed, or one collected by a producer the row does not declare.

  An `:unknown` result may be silenced only by an override (a waiver) that has
  a named approver and an expiry, and only until that expiry. See `silencer/4`.

  Sources: a row's `evidence_producer`, its `operating_process`, and, for
  `VENDOR` rows, its `vendor_ref`. Each declared source needs its own fresh
  artifact whose `collector` equals the reference string. A process that did
  not run in its window is therefore overdue, and shows as unknown.
  """

  alias AshCompliance.Ownership.{ControlFile, Criteria, Evidence, Frequency}

  @subject_type "evidence_freshness"
  @subject_id "control"

  @type state :: :evidenced | :owned | :not_applicable | :unknown
  @type result :: %{
          criterion: String.t(),
          state: state(),
          reason: atom() | nil,
          detail: String.t(),
          sources: [String.t()],
          latest_at: DateTime.t() | nil,
          silenced_by: map() | nil
        }

  @doc "The finding subject type freshness findings are filed under."
  def subject_type, do: @subject_type

  @doc "The finding subject id freshness findings are filed under."
  def subject_id, do: @subject_id

  @doc "The override `rule_id` that can waive a criterion's freshness finding."
  @spec rule_id(String.t()) :: String.t()
  def rule_id(criterion), do: "evidence-freshness:" <> criterion

  @doc """
  Evaluates every in-scope criterion.

  `loaded` is the result of `AshCompliance.Ownership.ControlFile.load/1`.
  `artifacts` is a map of criterion id to a list of artifacts (structs or
  maps with `:collector`, `:collected_at` and `:hash`).

  Options: `:categories` (default `[:security]`), `:now` (default now),
  `:overrides` (a list of override maps or structs).
  """
  @spec evaluate_all({:ok, map()} | {:error, term()}, map(), keyword()) :: [result()]
  def evaluate_all(loaded, artifacts, opts \\ []) do
    categories = Keyword.get(opts, :categories, [:security])
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    overrides = Keyword.get(opts, :overrides, [])

    for %{id: id} <- Criteria.in_categories(categories) do
      id
      |> evaluate_criterion(loaded, Map.get(artifacts, id, []), now)
      |> silence(overrides, now)
    end
  end

  defp evaluate_criterion(id, {:error, error}, _artifacts, _now),
    do: unknown(id, file_reason(error), ControlFile.describe_error(error))

  defp evaluate_criterion(id, {:ok, %{rows: rows}}, artifacts, now) do
    case Enum.filter(rows, &(is_map(&1) and Map.get(&1, "id") == id)) do
      [] ->
        unknown(id, :no_row, "the control file has no row for this criterion")

      [row] ->
        evaluate_row(id, row, artifacts, now)

      _many ->
        unknown(id, :duplicate_row, "the control file has more than one row for this criterion")
    end
  end

  defp file_reason({:missing, _}), do: :control_file_missing
  defp file_reason({:malformed_json, _}), do: :control_file_malformed
  defp file_reason({:malformed, _}), do: :control_file_malformed
  defp file_reason(_), do: :control_file_unreadable

  @doc """
  Evaluates one row against the artifacts recorded for it.
  """
  @spec evaluate_row(String.t(), term(), [term()], DateTime.t()) :: result()
  def evaluate_row(id, row, _artifacts, _now) when not is_map(row),
    do: unknown(id, :malformed_row, "the row is not an object")

  def evaluate_row(id, row, artifacts, now) do
    class = Map.get(row, "class")
    applicability = Map.get(row, "applicability")
    frequency = Map.get(row, "frequency")

    cond do
      class not in ControlFile.classes() ->
        unknown(id, :unknown_class, "class #{inspect(class)} is not recognised")

      applicability == "not_applicable" ->
        not_applicable(id, row)

      applicability != "applicable" ->
        unknown(
          id,
          :invalid_applicability,
          "applicability #{inspect(applicability)} is not recognised"
        )

      blank?(Map.get(row, "owner_role")) ->
        unknown(id, :no_owner_role, "no owner role")

      not Frequency.valid?(frequency) ->
        unknown(id, :unknown_frequency, "frequency #{inspect(frequency)} is not recognised")

      true ->
        {:ok, window} = Frequency.window_seconds(frequency)
        evaluate_sources(id, row, class, artifacts, now, window)
    end
  end

  defp not_applicable(id, row) do
    if blank?(Map.get(row, "rationale")) do
      unknown(id, :no_rationale, "declared not applicable without a rationale")
    else
      base(id, :not_applicable, nil, "declared not applicable: #{Map.get(row, "rationale")}")
    end
  end

  defp evaluate_sources(id, row, class, artifacts, now, window) do
    sources = sources(row, class)

    cond do
      sources == [] and class == "PLATFORM-ENFORCED" ->
        base(id, :owned, nil, "enforced by the platform; no evidence source to age")

      sources == [] ->
        unknown(id, :no_source, "no evidence producer, operating process or vendor reference")

      true ->
        outcomes = Enum.map(sources, &{&1, source_outcome(&1, artifacts, now, window)})
        summarise(id, outcomes)
    end
  end

  defp sources(row, class) do
    [Map.get(row, "evidence_producer"), Map.get(row, "operating_process")]
    |> Kernel.++(if class == "VENDOR", do: [Map.get(row, "vendor_ref")], else: [])
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp summarise(id, outcomes) do
    names = Enum.map(outcomes, &elem(&1, 0))
    failures = for {source, {:unknown, reason}} <- outcomes, do: {source, reason}

    case failures do
      [] ->
        latest = outcomes |> Enum.map(fn {_, {:fresh, at}} -> at end) |> Enum.min(DateTime)

        %{
          base(id, :evidenced, nil, "fresh evidence from #{Enum.join(names, ", ")}")
          | sources: names,
            latest_at: latest
        }

      [{_, reason} | _] ->
        detail = Enum.map_join(failures, "; ", fn {source, why} -> "#{source}: #{why}" end)
        %{unknown(id, reason, detail) | sources: names}
    end
  end

  defp source_outcome(source, artifacts, now, window) do
    mine = Enum.filter(artifacts, &(field(&1, :collector) == source))

    case mine do
      [] ->
        {:unknown, :no_evidence}

      _ ->
        classified = Enum.map(mine, &classify(&1, now))
        valid = for {:ok, at} <- classified, do: at

        case valid do
          [] -> {:unknown, worst_invalid(classified)}
          _ -> freshest(Enum.max(valid, DateTime), now, window)
        end
    end
  end

  defp freshest(at, now, window) do
    if DateTime.diff(now, at) <= window, do: {:fresh, at}, else: {:unknown, :stale}
  end

  defp worst_invalid(classified) do
    reasons = for {:error, reason} <- classified, do: reason

    Enum.find([:malformed_timestamp, :malformed_artifact, :future_dated], &(&1 in reasons)) ||
      :malformed_artifact
  end

  defp classify(artifact, now) do
    with {:ok, at} <- parse_time(field(artifact, :collected_at)),
         :ok <- check_hash(field(artifact, :hash)),
         :ok <- check_not_future(at, now) do
      {:ok, at}
    end
  end

  defp parse_time(%DateTime{} = at), do: {:ok, at}

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> {:error, :malformed_timestamp}
    end
  end

  defp parse_time(_), do: {:error, :malformed_timestamp}

  defp check_hash(hash),
    do: if(Evidence.hash?(hash), do: :ok, else: {:error, :malformed_artifact})

  defp check_not_future(at, now) do
    if DateTime.diff(at, now) > Evidence.skew_seconds(), do: {:error, :future_dated}, else: :ok
  end

  defp field(%{} = artifact, key), do: Map.get(artifact, key)
  defp field(_, _), do: nil

  defp base(id, state, reason, detail) do
    %{
      criterion: id,
      state: state,
      reason: reason,
      detail: detail,
      sources: [],
      latest_at: nil,
      silenced_by: nil
    }
  end

  defp unknown(id, reason, detail), do: base(id, :unknown, reason, detail)

  defp silence(%{state: :unknown, criterion: id} = result, overrides, now) do
    case silencer(overrides, id, now) do
      nil -> result
      override -> %{result | silenced_by: describe(override)}
    end
  end

  defp silence(result, _overrides, _now), do: result

  @doc """
  The override silencing `criterion` at `now`, or `nil`.

  An override silences only when all of these hold: it is a waiver for
  `rule_id(criterion)`; it has a named approver; it has an expiry; it has
  started; `now` is before the expiry; and it is scoped organization-wide or
  to this criterion's freshness subject. An override missing any of these is
  ignored, and one past its expiry stops silencing at that instant.
  """
  @spec silencer([term()], String.t(), DateTime.t()) :: term() | nil
  def silencer(overrides, criterion, %DateTime{} = now) do
    rule = rule_id(criterion)
    Enum.find(overrides, &silences?(&1, rule, now))
  end

  defp silences?(override, rule, now) do
    kind = field(override, :kind)
    expires_at = field(override, :expires_at)
    starts_at = field(override, :starts_at)

    kind in [:waive, "waive"] and
      field(override, :rule_id) == rule and
      not blank?(field(override, :approver)) and
      match?(%DateTime{}, expires_at) and
      DateTime.compare(now, expires_at) == :lt and
      (is_nil(starts_at) or
         (match?(%DateTime{}, starts_at) and DateTime.compare(starts_at, now) != :gt)) and
      scope_matches?(override)
  end

  defp scope_matches?(override) do
    type = field(override, :scope_subject_type)
    id = field(override, :scope_subject_id)

    (is_nil(type) and is_nil(id)) or (type == @subject_type and id == @subject_id)
  end

  defp describe(override) do
    %{
      approver: field(override, :approver),
      expires_at: field(override, :expires_at),
      reason: field(override, :reason)
    }
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")
end
