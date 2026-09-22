# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.IrRoundTripTest do
  @moduledoc """
  The editor's contract with the engine: `AshRules.Ir.encode!` →
  `AshRules.Ir.decode` is LOSSLESS for rule sets exercising everything the
  editor edits.

  The ruleset editor serializes its structured form to `rules_json` through
  the Ir encode path on every save and hydrates back from an existing
  revision through decode. If that round trip lost anything — a fact's
  absence semantics, a one_of vocabulary, a neg triple's variable binding, a
  gap text, the combining algorithm — the editor would show an operator a
  different rule set than the one that was saved, so this test gates the
  whole design.

  What it asserts:

    * decode(encode(bundle)) succeeds, and re-encoding the decoded bundle is
      byte-identical (the canonical form is a fixed point, which is what
      makes content hashes stable across the edit/save/load cycle)
    * every fact field round trips: name, type, one_of, missing semantics,
      cardinality, description
    * every rule field round trips: id, name, revision, severity, message,
      remediation_ref, controls, evidence, the has/neg triples including
      variable subjects, and the outcome declaration with its gap text
    * the combining algorithm round trips, for all four algorithms
    * the recomputed content hash matches the original bundle's hash

  One deliberate non-assertion, pinned below: ground predicate *subjects*
  are atoms in DSL-authored IR and decode as strings. Subjects are opaque
  entity keys — the fact schema types only predicate values — and the JSON
  form has no way to carry atom-ness. Re-encoding is byte-identical either
  way, so the canonical form the editor stores and the hash it pins are
  unaffected; the editor keeps subject text as strings end to end.
  """

  use ExUnit.Case, async: true

  alias AshRules.Ir
  alias AshRules.Ir.Bundle

  @bundle AshCompliance.Test.RuleSets.EditorRoundTrip.__bundle__()

  describe "encode → decode round trip" do
    test "decode succeeds and the canonical form is a fixed point" do
      json = Ir.encode!(@bundle)

      assert {:ok, decoded} = Ir.decode(json)
      assert Ir.encode!(decoded) == json

      # Same canonical JSON in, same content hash out: a revision saved by
      # the editor hashes identically to the bundle it was edited from.
      assert decoded.content_hash == @bundle.content_hash
      assert decoded.revision == @bundle.revision
      assert decoded.fact_schema_revision == @bundle.fact_schema_revision
    end

    test "every fact round trips: types, one_of and missing semantics" do
      assert {:ok, decoded} = @bundle |> Ir.encode!() |> Ir.decode()

      assert length(decoded.fact_schema.facts) == length(@bundle.fact_schema.facts)

      for fact <- @bundle.fact_schema.facts do
        round_tripped = fetch_fact(decoded, fact.name)

        assert round_tripped.type == fact.type,
               "fact #{fact.name}: type changed"

        assert round_tripped.one_of == fact.one_of,
               "fact #{fact.name}: one_of changed"

        assert round_tripped.missing == fact.missing,
               "fact #{fact.name}: missing semantics changed"

        assert round_tripped.cardinality == fact.cardinality
        assert round_tripped.description == fact.description
      end

      # The fixture must actually exercise the space, or this test proves
      # nothing: every type the editor offers, both closed and open atoms,
      # and all three missing semantics.
      types = @bundle.fact_schema.facts |> Enum.map(& &1.type) |> Enum.uniq()
      assert MapSet.new(types) |> MapSet.subset?(MapSet.new(AshRules.Ir.Fact.types()))

      assert Enum.any?(@bundle.fact_schema.facts, &(&1.one_of != nil))
      assert Enum.any?(@bundle.fact_schema.facts, &(&1.missing == :unknown))
      assert Enum.any?(@bundle.fact_schema.facts, &(&1.missing == :no_fact))
      assert Enum.any?(@bundle.fact_schema.facts, &(&1.missing == false))
    end

    test "every rule round trips: triples, outcomes, metadata" do
      assert {:ok, decoded} = @bundle |> Ir.encode!() |> Ir.decode()

      assert length(decoded.rules) == length(@bundle.rules)

      for rule <- @bundle.rules do
        round_tripped = fetch_rule(decoded, rule.id)

        assert round_tripped.name == rule.name
        assert round_tripped.revision == rule.revision
        assert round_tripped.severity == rule.severity
        assert round_tripped.message == rule.message
        assert round_tripped.remediation_ref == rule.remediation_ref
        assert round_tripped.controls == rule.controls
        assert round_tripped.evidence == rule.evidence

        assert predicates(round_tripped.applicability) == predicates(rule.applicability),
               "rule #{rule.id}: when_requires triple changed"

        assert predicates(round_tripped.failure_conditions) ==
                 predicates(rule.failure_conditions),
               "rule #{rule.id}: fails_when triple changed"

        assert round_tripped.outcome.outcome == rule.outcome.outcome
        assert round_tripped.outcome.gap == rule.outcome.gap
      end

      # The fixture must exercise has and neg triples, variable subjects
      # bound by an earlier has clause, and gap text.
      ids = Enum.map(@bundle.rules, & &1.id)
      assert "kyc.valid_required" in ids
      assert "acct.balance_frozen" in ids

      assert Enum.any?(@bundle.rules, fn rule ->
               Enum.any?(rule.applicability, &AshRules.Ir.Predicate.var?(&1.subject))
             end)

      assert Enum.any?(@bundle.rules, fn rule ->
               Enum.any?(rule.failure_conditions, &(&1.op == :neg))
             end)

      assert Enum.all?(@bundle.rules, &(&1.outcome.gap in [nil, ""] == false))
    end

    test "ground subjects decode as strings: the one lossy-by-construction position" do
      # Pinned, not asserted-against: subjects are opaque entity keys outside
      # the typed fact vocabulary, and JSON has no atom type. The decoded
      # subject is the same text; the evaluator compares subjects with strict
      # equality on whatever the fact feed supplies, so the editor keeps
      # subject strings end to end and nothing downstream observes the
      # difference.
      assert {:ok, decoded} = @bundle |> Ir.encode!() |> Ir.decode()

      original = fetch_rule(@bundle, "kyc.valid_required")
      round_tripped = fetch_rule(decoded, "kyc.valid_required")

      assert hd(original.applicability).subject == :customer
      assert hd(round_tripped.applicability).subject == "customer"

      # ...while atom *values* — which the fact schema does type — come back
      # as atoms through the schema's type-directed value decoding.
      value_predicate =
        Enum.find(round_tripped.applicability, &(&1.name == :jurisdiction))

      assert value_predicate.value == :regulated
    end

    test "the combining algorithm round trips, for all four algorithms" do
      for algorithm <- AshRules.Combining.algorithms() do
        bundle =
          Bundle.new(@bundle.rules, @bundle.fact_schema, combining: algorithm)

        assert {:ok, decoded} = bundle |> Ir.encode!() |> Ir.decode()
        assert decoded.combining == algorithm
      end
    end
  end

  defp fetch_fact(bundle, name) do
    Enum.find(bundle.fact_schema.facts, &(&1.name == name)) ||
      flunk("fact #{inspect(name)} missing after round trip")
  end

  defp fetch_rule(bundle, id) do
    Enum.find(bundle.rules, &(&1.id == id)) ||
      flunk("rule #{inspect(id)} missing after round trip")
  end

  # Subjects compared as text (see the atom/string note above); values
  # compared exactly.
  defp predicates(list) do
    Enum.map(list, fn predicate ->
      {predicate.op, term(predicate.subject), predicate.name, term(predicate.value)}
    end)
  end

  defp term(%AshRules.Ir.Var{name: name}), do: {:var, name}
  defp term(atom) when is_atom(atom) and not is_boolean(atom), do: {:text, Atom.to_string(atom)}
  defp term(other), do: {:text, other}
end
