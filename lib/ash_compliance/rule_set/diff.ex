# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.RuleSet.Diff do
  @moduledoc """
  What changed between two revisions of a rule set, by what they mean.

  Two revisions (`AshCompliance.Resources.RuleSetRevision` rows, or maps with the same
  fields) are compared over the rule bundle each pins (`rules_json`, the serialized
  `AshRules.Ir.Bundle`), never its text, so a re-encoding that changes nothing the rules
  say is not a change:

    * **layer**: the layer the rule set contributes to, and its combining algorithm (the
      bundle's, else the revision's);
    * **rules**: each rule by its id, added or removed, and for one in both, each property
      that changed: its name, revision, when it applies (`applicability`), what makes it
      fail (`failure_conditions`), its outcome, severity and message, the controls it maps
      to and the evidence it asks for;
    * **facts**: each fact of the fact schema the rules read, by its name.

  The lifecycle (`status`, the period) and the revision's name and label are not compared.

  The result is a list of plain maps, one per change, with no struct, so a host can render
  or store it without depending on a type from this package:

      %{
        aspect: :rules,                   # one of aspects/0
        kind: :added | :removed | :changed,
        subject: "kyc.valid_required",    # the rule id, fact name or layer property
        option: "severity" | nil,         # for :changed, the property that changed
        from: term(), to: term()          # the old and new value, as plain data
      }

  Unlike a definition that did not compile, a revision always pins a bundle, so one whose
  `rules_json` does not decode to a bundle with a list of rules is an error, not an empty
  rule set: `diff/2` returns `{:error, :unreadable_bundle}`.

  An empty list means nothing this compares changed. It does not mean the two revisions
  are identical; compare `content_hash` for that.
  """

  @typedoc "One change between two revisions."
  @type change :: %{
          aspect: atom(),
          kind: :added | :removed | :changed,
          subject: String.t() | nil,
          option: String.t() | nil,
          from: term(),
          to: term()
        }

  @doc """
  What `diff/2` compares, in the order a reader should see it, each with an English label.
  A host translates the labels in its own catalogue.
  """
  @spec aspects() :: [{atom(), String.t()}]
  def aspects do
    [
      layer: "Layer",
      rules: "Rules",
      facts: "Facts"
    ]
  end

  @doc """
  The changes from `old` to `new`, two rule set revisions (or maps with a `:rules_json`),
  or `{:error, :unreadable_bundle}` when either bundle does not decode.
  """
  @spec diff(map(), map()) :: {:ok, [change()]} | {:error, :unreadable_bundle}
  def diff(old, new) do
    with {:ok, old_bundle} <- bundle(old),
         {:ok, new_bundle} <- bundle(new) do
      {:ok,
       keyed(:layer, layer(old, old_bundle), layer(new, new_bundle)) ++
         keyed(:rules, named(old_bundle["rules"], "id"), named(new_bundle["rules"], "id")) ++
         keyed(:facts, facts(old_bundle), facts(new_bundle))}
    end
  end

  defp bundle(%{rules_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"rules" => rules} = bundle} when is_list(rules) -> {:ok, bundle}
      _other -> {:error, :unreadable_bundle}
    end
  end

  defp bundle(_revision), do: {:error, :unreadable_bundle}

  defp layer(revision, bundle) do
    %{
      "layer" => text(Map.get(revision, :layer)),
      "combining" => bundle["combining"] || text(Map.get(revision, :combining))
    }
  end

  defp text(nil), do: nil
  defp text(value), do: to_string(value)

  defp facts(%{"fact_schema" => facts}) when is_list(facts), do: named(facts, "name")
  defp facts(_bundle), do: %{}

  defp named(entries, key) do
    for %{} = entry <- entries, into: %{}, do: {entry[key], Map.delete(entry, key)}
  end

  # The changes between two maps of named subjects under `aspect`: added and removed names,
  # and, for a name in both, each property whose value differs. Values that are maps are
  # compared property by property; any other value is compared whole.
  defp keyed(aspect, old, new) do
    names = old |> Map.keys() |> Kernel.++(Map.keys(new)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(names, fn name ->
      case {Map.fetch(old, name), Map.fetch(new, name)} do
        {:error, {:ok, value}} -> [change(aspect, :added, name, nil, nil, value)]
        {{:ok, value}, :error} -> [change(aspect, :removed, name, nil, value, nil)]
        {{:ok, same}, {:ok, same}} -> []
        {{:ok, from}, {:ok, to}} -> properties(aspect, name, from, to)
      end
    end)
  end

  defp properties(aspect, name, %{} = from, %{} = to) do
    from
    |> Map.keys()
    |> Kernel.++(Map.keys(to))
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
    |> Enum.flat_map(fn option ->
      case {Map.get(from, option), Map.get(to, option)} do
        {same, same} -> []
        {old, new} -> [change(aspect, :changed, name, option, old, new)]
      end
    end)
  end

  defp properties(aspect, name, from, to), do: [change(aspect, :changed, name, nil, from, to)]

  defp change(aspect, kind, subject, option, from, to) do
    %{
      aspect: aspect,
      kind: kind,
      subject: subject && to_string(subject),
      option: option && to_string(option),
      from: from,
      to: to
    }
  end
end
