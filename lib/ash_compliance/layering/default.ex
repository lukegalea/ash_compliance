# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Layering.Default do
  @moduledoc """
  The six-rank authority scheme, declared as data:

  | Rank | Layer                  | May                                              |
  |------|------------------------|--------------------------------------------------|
  | 1    | `global_non_waivable`  | add; its rules refuse waivers                    |
  | 2    | `global_mandatory`     | add                                              |
  | 3    | `profile_refinement`   | add; exclude inner rules; refine self and inner  |
  | 4    | `tenant_strengthening` | add                                              |
  | 5    | `approved_override`    | add; waive any waivable rule; replace inner rules |
  | 6    | `tenant_supplement`    | add                                              |

  Lower rank wins when two layers declare the same rule id
  (`declarations: :outer_wins`), every edit is checked in source order
  against the winning declaration (`edits: :against_declarations`), and the
  first refusal stops the compile (`refusals: :first`). `:parameterize` and
  `:tighten` are declared nowhere, so both are refused.

  `AshCompliance.Compiler.compile/1` uses this scheme unless told otherwise,
  and `AshCompliance.Compiler.Layer` answers from it. The refusal messages
  are the ones the compiler has always given.
  """

  use AshCompliance.Layering

  @impl true
  def layers do
    [
      [name: :global_non_waivable, ops: [:add], protected: [:waive]],
      [name: :global_mandatory, ops: [:add]],
      [name: :profile_refinement, ops: [:add, exclude: :inner, refine: :self_and_inner]],
      [name: :tenant_strengthening, ops: [:add]],
      [name: :approved_override, ops: [:add, waive: :any, replace: :inner]],
      [name: :tenant_supplement, ops: [:add]]
    ]
  end

  @impl true
  def precedence do
    [declarations: :outer_wins, edits: :against_declarations, refusals: :first]
  end

  @impl true
  def refusal_message(reason, contribution, target, detail) do
    rule = inspect(contribution.rule_id)

    case {reason, contribution.op} do
      {:undeclared, :waive} ->
        "waiver for rule #{rule} targets a rule no active layer declares"

      {:protected, :waive} ->
        "waiver for rule #{rule} refused: the rule is declared in the " <>
          "non-waivable global layer and can never be waived"

      {:blank_replacement, :replace} ->
        "replacement for rule #{rule} carries no replacement rule set"

      {:undeclared, :replace} ->
        "replacement for rule #{rule} targets a rule no active layer declares"

      {:out_of_reach, :replace} ->
        "replacement for rule #{rule} refused: it is declared in the " <>
          "#{inspect(target.layer)} layer, which outranks approved overrides. Only tenant " <>
          "supplements can be replaced"

      {:replacement_invalid, :replace} ->
        "replacement rule set for #{rule} does not decode: " <>
          (List.wrap(detail[:errors]) |> Enum.join("; "))

      {:op_not_allowed, :parameterize} ->
        "profile parameterizes #{rule}: the rule IR has no parameter binding in " <>
          "v1 — precompute parameterized facts instead"

      {:undeclared, :exclude} ->
        "profile excludes rule #{rule}, which no active layer declares"

      {:out_of_reach, :exclude} ->
        "profile cannot exclude rule #{rule}: it is declared in a layer that " <>
          "outranks profile refinements"

      {:undeclared, :refine} ->
        "profile refines rule #{rule}, which no active layer declares"

      {:out_of_reach, :refine} ->
        "profile cannot refine rule #{rule}: it is declared in a mandatory " <>
          "layer that outranks profile refinements"

      _ ->
        AshCompliance.Layering.default_refusal_message(reason, contribution, target, detail)
    end
  end
end
