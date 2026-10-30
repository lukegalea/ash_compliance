# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Compiler.Resolution do
  @moduledoc """
  What `AshCompliance.Compiler.resolve/3` returns: the effective rules for one
  context under one scheme, why each one is there, and what was refused.

  A resolution is a read, never stored. A resolution with refusals is not a
  valid effective set — `AshCompliance.Compiler.compile/1` refuses it — but
  under `refusals: :all` its rules show what would apply with the refused
  contributions ignored, which is what an explanation screen wants.

  Fields:

    * `:rules` — effective `AshRules.Ir.Rule`s, sorted by id, params bound.
    * `:combining` — the algorithm of the highest-precedence winning rule.
    * `:params` — `%{rule_id => %{param => value}}`, the effective params.
    * `:lineage` — `%{rule_id => [step]}`, in application order: the
      declaring `:add` (or `:replace`) first, then each edit that touched it.
    * `:excluded` — the `:exclude`/`:waive` steps that removed a rule.
    * `:refusals` — `[refusal]`, in the order they were found.
    * `:winners` — the effective contributions (rule, layer, params, source).
    * `:declarations` — the admitted `:add` contributions, as supplied.
    * `:replacements` — contributions the accepted `:replace` edits introduced.
    * `:scheme`, `:context` — what was resolved against.
  """

  alias AshCompliance.Layering

  @typedoc "One application of a contribution to a rule."
  @type step() :: %{
          rule_id: String.t(),
          op: Layering.op(),
          layer: Layering.layer(),
          source_id: term(),
          source: term(),
          scope: Layering.scope(),
          params: map()
        }

  @typedoc "A refused contribution."
  @type refusal() :: %{
          reason: Layering.refusal_reason(),
          message: String.t(),
          rule_id: String.t() | nil,
          op: Layering.op() | atom(),
          layer: Layering.layer() | nil,
          source_id: term(),
          source: term(),
          detail: map()
        }

  @type t() :: %__MODULE__{
          rules: [AshRules.Ir.Rule.t()],
          combining: AshRules.Combining.algorithm(),
          params: %{String.t() => map()},
          lineage: %{String.t() => [step()]},
          excluded: [step()],
          refusals: [refusal()],
          winners: [map()],
          declarations: [map()],
          replacements: [map()],
          scheme: module(),
          context: Layering.context()
        }

  defstruct rules: [],
            combining: :deny_overrides,
            params: %{},
            lineage: %{},
            excluded: [],
            refusals: [],
            winners: [],
            declarations: [],
            replacements: [],
            scheme: nil,
            context: %{}

  @doc "True when nothing was refused."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{refusals: refusals}), do: refusals == []

  @doc "The refusal messages, de-duplicated, in order."
  @spec messages(t()) :: [String.t()]
  def messages(%__MODULE__{refusals: refusals}),
    do: refusals |> Enum.map(& &1.message) |> Enum.uniq()

  @doc "The effective params of `rule_id` (`%{}` when it has none or is not effective)."
  @spec params_for(t(), String.t()) :: map()
  def params_for(%__MODULE__{params: params}, rule_id), do: Map.get(params, rule_id, %{})
end
