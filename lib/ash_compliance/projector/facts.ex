# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Projector.Facts do
  @moduledoc """
  Fact extraction for the compliance translation: from an event to the fact
  triples `AshRules.evaluate/3` consumes.

  The default `:metadata` strategy reads the event's metadata map, the
  JSON-shaped payload AshEvents persists alongside every event:

      metadata: %{
        "organization_id" => "...",
        "subject_type" => "customer",
        "subject_id" => "cus_123",
        "correlation_id" => "evt-42",
        "facts" => [
          ["customer", "status", "active"],
          ["customer", "jurisdiction", "regulated"],
          ["customer", "has_valid_kyc", true]
        ]
      }

  Predicate names are matched against the bundle's fact schema by string —
  no atom is ever created from event payload, and a predicate the schema does
  not declare is an error, not a silent drop. Values are used as-is
  (JSON already maps them to the right Elixir terms).

  Hosts with richer event shapes declare an MFA strategy:

      use AshCompliance.Projector,
        facts: {MyApp.Compliance.Facts, :from_event, []}

  The function receives the event (plus any args) and returns
  `{:ok, facts}` or `{:error, reason}`.

  `snapshot_hash/1` is the SHA-256 over the canonical JSON of the extracted
  fact payload — the fact snapshot an auditor can re-derive from the event.
  """

  @doc "Extracts facts per the projector's `:facts` option."
  @spec extract(keyword(), map(), AshRules.Ir.Bundle.t()) ::
          {:ok, AshRules.Facts.t() | [AshRules.Facts.triple()]} | {:error, term()}
  def extract(opts, event, bundle) do
    case Keyword.get(opts, :facts, :metadata) do
      :metadata ->
        from_metadata(event, bundle)

      {module, function, args} ->
        apply(module, function, args ++ [event])

      other ->
        {:error, "unknown facts strategy #{inspect(other)}"}
    end
  end

  @doc "The `:metadata` strategy: fact triples from `event.metadata[\"facts\"]`."
  @spec from_metadata(map(), AshRules.Ir.Bundle.t()) ::
          {:ok, [AshRules.Facts.triple()]} | {:error, String.t()}
  def from_metadata(event, bundle) do
    metadata = event[:metadata] || event.metadata || %{}
    default_subject = metadata["subject_id"]

    metadata["facts"]
    |> List.wrap()
    |> Enum.map(fn
      [subject, predicate, value] -> {subject, predicate, value}
      [predicate, value] -> {default_subject, predicate, value}
      {subject, predicate, value} -> {subject, predicate, value}
    end)
    |> resolve_predicates(bundle)
  end

  defp resolve_predicates(triples, bundle) do
    declared =
      Map.new(bundle.fact_schema.facts, fn fact ->
        {Atom.to_string(fact.name), fact}
      end)

    Enum.reduce_while(triples, {:ok, []}, fn
      {subject, predicate, value}, {:ok, acc} ->
        case Map.fetch(declared, predicate) do
          {:ok, fact} ->
            case AshRules.Ir.Fact.decode_value(fact.type, value) do
              {:ok, converted} -> {:cont, {:ok, [{subject, fact.name, converted} | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          :error ->
            {:halt, {:error, "predicate #{inspect(predicate)} is not in the fact schema"}}
        end

      _other, _acc ->
        {:halt,
         {:error,
          "facts must be [subject, predicate, value] or [predicate, value] triples, " <>
            "with predicate names matching the fact schema"}}
    end)
    |> case do
      {:ok, facts} -> {:ok, Enum.reverse(facts)}
      error -> error
    end
  end

  @doc """
  The SHA-256 (hex) over the canonical JSON of the event's fact payload —
  the fact snapshot hash recorded on every `ComplianceEvaluation`.
  """
  @spec snapshot_hash(map()) :: String.t()
  def snapshot_hash(event) do
    metadata = event[:metadata] || event.metadata || %{}

    metadata
    |> Map.get("facts", [])
    |> Enum.map(&normalize_for_hash/1)
    |> Enum.sort()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_for_hash([subject, predicate, value]),
    do: %{"subject" => to_string(subject), "predicate" => to_string(predicate), "value" => value}

  defp normalize_for_hash([predicate, value]),
    do: %{"subject" => nil, "predicate" => to_string(predicate), "value" => value}

  defp normalize_for_hash(other), do: %{raw: other}
end
