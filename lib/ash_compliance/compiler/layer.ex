# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Compiler.Layer do
  @moduledoc """
  The six-rank default precedence, answered from
  `AshCompliance.Layering.Default`.

  Non-waivable global > global mandatory > profile refinements > tenant
  strengthening > approved replacements/waivers > tenant supplements. Lower
  rank wins on conflict (same rule id). The order and permissions are
  declared once, in `AshCompliance.Layering.Default`; these functions are the
  stable vocabulary `RuleSetRevision` and the editor are built on. A host
  that needs a different order declares its own `AshCompliance.Layering`
  scheme and passes it to the compiler — it does not change this module.
  """

  alias AshCompliance.Layering
  alias AshCompliance.Layering.Default

  @override :approved_override
  @supplement :tenant_supplement

  @typedoc "A layer of the default precedence."
  @type t() ::
          :global_non_waivable
          | :global_mandatory
          | :profile_refinement
          | :tenant_strengthening
          | :approved_override
          | :tenant_supplement

  @doc "All layers, highest precedence first."
  @spec layers() :: [t(), ...]
  def layers, do: Layering.layers(Default)

  @doc "The rule-set layers a `RuleSetRevision` may declare (overrides are approval artifacts)."
  @spec revision_layers() :: [t(), ...]
  def revision_layers, do: Enum.reject(layers(), &(&1 == @override))

  @doc "The statuses a `RuleSetRevision` moves through."
  @spec statuses() :: [atom(), ...]
  def statuses, do: [:draft, :validated, :approved, :active, :retired, :revoked]

  @doc "The rank of a layer: lower outranks higher."
  @spec rank(t()) :: pos_integer()
  def rank(layer) do
    Layering.rank(Default, layer) ||
      raise ArgumentError, "#{inspect(layer)} is not a layer of the default precedence"
  end

  @doc "True if layer `a` outranks layer `b`."
  @spec outranks?(t(), t()) :: boolean()
  def outranks?(a, b), do: rank(a) < rank(b)

  @doc """
  True if an approved replacement may target a rule declared in `target`.
  Replacements may only displace rules that rank below `:approved_override` —
  i.e. tenant supplements. Baseline layers outrank approvals by design.
  """
  @spec replaceable?(t()) :: boolean()
  def replaceable?(target), do: Layering.reaches?(Default, @override, :replace, target)

  @doc """
  True if a waiver may target a rule declared in `target`. Only the
  non-waivable global layer refuses waivers.
  """
  @spec waivable?(t()) :: boolean()
  def waivable?(target), do: not Layering.protected?(Default, target, :waive)

  @doc "The rank of the override layer (for sorting contributions)."
  @spec override_layer() :: t()
  def override_layer, do: @override

  @doc "The rank of the supplement layer (the weakest contribution)."
  @spec supplement_layer() :: t()
  def supplement_layer, do: @supplement
end
