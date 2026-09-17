# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Compiler.Layer do
  @moduledoc """
  The fixed layering precedence, expressed as data.

  The design fixes the order — non-waivable global > global mandatory >
  profile refinements > tenant strengthening > approved replacements/waivers >
  tenant supplements — and the compiler refuses ad-hoc inheritance: a rule's
  precedence is determined entirely by the layer it was declared in, never by
  who compiled the bundle or when.

  Lower rank wins on conflict (same rule id). `rank/1` is the single source of
  the order; `outranks?/2` and the waiver/replace permission checks derive
  from it.
  """

  @non_waivable :global_non_waivable
  @mandatory :global_mandatory
  @refinement :profile_refinement
  @strengthening :tenant_strengthening
  @override :approved_override
  @supplement :tenant_supplement

  @layers [@non_waivable, @mandatory, @refinement, @strengthening, @override, @supplement]

  @typedoc "A layer of the fixed precedence."
  @type t() ::
          :global_non_waivable
          | :global_mandatory
          | :profile_refinement
          | :tenant_strengthening
          | :approved_override
          | :tenant_supplement

  @doc "All layers, highest precedence first."
  @spec layers() :: [t(), ...]
  def layers, do: @layers

  @doc "The rule-set layers a `RuleSetRevision` may declare (overrides are approval artifacts)."
  @spec revision_layers() :: [t(), ...]
  def revision_layers, do: [@non_waivable, @mandatory, @refinement, @strengthening, @supplement]

  @doc "The statuses a `RuleSetRevision` moves through."
  @spec statuses() :: [atom(), ...]
  def statuses, do: [:draft, :validated, :approved, :active, :retired, :revoked]

  @doc "The rank of a layer: lower outranks higher."
  @spec rank(t()) :: pos_integer()
  def rank(@non_waivable), do: 1
  def rank(@mandatory), do: 2
  def rank(@refinement), do: 3
  def rank(@strengthening), do: 4
  def rank(@override), do: 5
  def rank(@supplement), do: 6

  @doc "True if layer `a` outranks layer `b`."
  @spec outranks?(t(), t()) :: boolean()
  def outranks?(a, b), do: rank(a) < rank(b)

  @doc """
  True if an approved replacement may target a rule declared in `target`.
  Replacements may only displace rules that rank below `:approved_override` —
  i.e. tenant supplements. Baseline layers outrank approvals by design.
  """
  @spec replaceable?(t()) :: boolean()
  def replaceable?(target), do: rank(target) > rank(@override)

  @doc """
  True if a waiver may target a rule declared in `target`. Only the
  non-waivable global layer refuses waivers.
  """
  @spec waivable?(t()) :: boolean()
  def waivable?(@non_waivable), do: false
  def waivable?(_), do: true

  @doc "The rank of the override layer (for sorting contributions)."
  @spec override_layer() :: t()
  def override_layer, do: @override

  @doc "The rank of the supplement layer (the weakest contribution)."
  @spec supplement_layer() :: t()
  def supplement_layer, do: @supplement
end
