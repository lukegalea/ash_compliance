# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Layering do
  @moduledoc """
  A declared layering scheme: the ordered layers contributions are made at,
  what each layer may do to rules declared elsewhere, how conflicts resolve,
  and how a contribution's scope matches a resolution context.

  A scheme is a module, reviewed like code, passed explicitly to
  `AshCompliance.Compiler.resolve/3` or `AshCompliance.Compiler.compile/1`
  (`scheme:`). There is deliberately no application-env switch: one host may
  run several schemes side by side (a KYC slice on
  `AshCompliance.Layering.Default`, a vendor-requirements slice on its own
  five scope layers), and a global setting would silently move one of them.

      defmodule MyApp.RequirementLayers do
        use AshCompliance.Layering

        @impl true
        def layers do
          [
            [name: :ours, ops: [:add]],
            [name: :pmc, ops: [:add, tighten: :any, exclude: :any], scope_key: :pmc],
            [name: :job, ops: [:add, tighten: :any, exclude: :any], scope_key: :job]
          ]
        end
      end

  ## Layers

  `c:layers/0` lists the layers **outermost (highest precedence) first**. Each
  layer is a keyword list or map:

    * `:name` — the layer atom contributions declare.
    * `:ops` — the operations a contribution *at this layer* may perform, each
      with its **reach**: which target layers it may touch, relative to this
      one. A bare atom means reach `:any`. `:add` declares a rule and has no
      reach. Reaches: `:any`, `:outer` (strictly outer), `:self_and_outer`,
      `:inner` (strictly inner), `:self_and_inner`, or an explicit list of
      layer names.
    * `:protected` — operations that may never target a rule *declared at
      this layer*, whatever the editor's reach (e.g. `[:waive]` for a
      non-waivable floor). Defaults to `[]`.
    * `:scope_key` — when set, every contribution at this layer must carry a
      scope with this key; an unscoped contribution there is refused rather
      than silently applying everywhere. Defaults to `nil`.

  The operations:

    * `:add` — declare a rule (with optional `params` and their `strength`).
    * `:tighten` — make a declared rule's params strictly stronger. Every
      supplied param must be declared on the target with a strength direction
      and be strictly stronger than the current value (see `stronger?/4`);
      anything else is refused.
    * `:exclude` — remove a rule from what applies. Scoped, an exclusion only
      narrows what applies for contexts its scope matches; an outer read
      never sees it.
    * `:refine` — patch a rule's severity and/or message in place.
    * `:waive` — an approved, time-bounded exclusion (the source enforces the
      bounds; the scheme decides which layers may be waived).
    * `:replace` — displace a rule with approved replacement rules.
    * `:parameterize` — set params without the strictly-stronger check.

  ## Precedence

  `c:precedence/0` returns a keyword list or map (missing keys default):

    * `:declarations` — `:outer_wins` (default) or `:inner_wins`: which layer's
      declaration stands when two layers add the same rule id.
    * `:edits` — `:cascade` (default): every contribution applies in layer
      order, outermost first, each against the result so far (so a second
      tighten must beat the first). `:against_declarations`: all adds are
      collected first and every edit is checked, in the order supplied,
      against the winning declaration (the six-rank semantics of
      `AshCompliance.Layering.Default`).
    * `:refusals` — `:all` (default): refused contributions are skipped and
      every refusal is reported. `:first`: resolution stops at the first.

  ## Scope

  `c:scope_matches?/2` decides whether a contribution's scope admits it under
  a resolution context. The default (`default_scope_matches?/2`) admits an
  unscoped (`nil` or `%{}`) contribution everywhere, and a scoped one when
  every scope key is present in the context with an overlapping value (either
  side may be a list): scope `%{property_group: g1}` matches context
  `%{property_group: [g1, g2]}`.
  """

  alias AshRules.Ir.Rule

  @typedoc "A layer name."
  @type layer() :: atom()

  @typedoc "An operation a contribution performs."
  @type op() :: :add | :tighten | :exclude | :refine | :waive | :replace | :parameterize

  @typedoc "Which target layers an operation at a given layer may touch."
  @type reach() :: :any | :outer | :self_and_outer | :inner | :self_and_inner | [layer()]

  @typedoc "A normalized layer declaration."
  @type layer_spec() :: %{
          name: layer(),
          ops: %{optional(op()) => reach()},
          protected: [op()],
          scope_key: atom() | nil
        }

  @typedoc "Normalized precedence semantics."
  @type precedence() :: %{
          declarations: :outer_wins | :inner_wins,
          edits: :cascade | :against_declarations,
          refusals: :all | :first
        }

  @typedoc "Where a contribution applies. `nil` or `%{}` applies everywhere."
  @type scope() :: %{optional(atom()) => term()} | nil

  @typedoc "What a resolution is for: e.g. `%{pmc: id, property_group: [ids], job: id}`."
  @type context() :: %{optional(atom()) => term()}

  @typedoc "How a param's strength is ordered."
  @type direction() :: :at_least | :at_most | :superset | {:ranked, [term()]}

  @typedoc "Why a contribution was refused."
  @type refusal_reason() ::
          :unknown_layer
          | :unknown_op
          | :unscoped
          | :op_not_allowed
          | :blank_replacement
          | :undeclared
          | :protected
          | :out_of_reach
          | :replacement_invalid
          | :already_declared
          | :nothing_to_tighten
          | :unknown_param
          | :no_direction
          | :not_stronger
          | :unbound_param

  @ops [:add, :tighten, :exclude, :refine, :waive, :replace, :parameterize]
  @reaches [:any, :outer, :self_and_outer, :inner, :self_and_inner]

  @doc "Layers, outermost (highest precedence) first."
  @callback layers() :: [keyword() | map(), ...]

  @doc "Precedence semantics; missing keys take the defaults."
  @callback precedence() :: keyword() | map()

  @doc "True if a contribution with `scope` applies under `context`."
  @callback scope_matches?(scope(), context()) :: boolean()

  @doc "True if `proposed` is strictly stronger than `current` under `direction`."
  @callback stronger?(direction(), current :: term(), proposed :: term()) :: boolean()

  @doc """
  The refusal message for `reason`. `contribution` is the refused
  contribution, `target` the contribution it targeted (or `nil`), `detail`
  reason-specific data (e.g. `%{param: :min_amount, current: 1, proposed: 0}`).
  """
  @callback refusal_message(
              refusal_reason(),
              contribution :: map(),
              target :: map() | nil,
              detail :: map()
            ) :: String.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour AshCompliance.Layering

      @impl AshCompliance.Layering
      def precedence, do: []

      @impl AshCompliance.Layering
      def scope_matches?(scope, context),
        do: AshCompliance.Layering.default_scope_matches?(scope, context)

      @impl AshCompliance.Layering
      def stronger?(direction, current, proposed),
        do: AshCompliance.Layering.default_stronger?(direction, current, proposed)

      @impl AshCompliance.Layering
      def refusal_message(reason, contribution, target, detail),
        do: AshCompliance.Layering.default_refusal_message(reason, contribution, target, detail)

      defoverridable precedence: 0, scope_matches?: 2, stronger?: 3, refusal_message: 4
    end
  end

  # --- the compiled scheme ------------------------------------------------------

  @typedoc "A scheme module, normalized once for a resolution."
  @type compiled() :: %{
          module: module(),
          names: [layer()],
          specs: %{layer() => layer_spec()},
          ranks: %{layer() => pos_integer()},
          precedence: precedence()
        }

  @doc """
  Normalizes a scheme module once. Raises `ArgumentError` on a malformed
  declaration (unknown op or reach, duplicate layer) — a scheme is code and
  fails at the first use, not per contribution.
  """
  @spec compile(module() | compiled()) :: compiled()
  def compile(%{module: _, specs: _} = compiled), do: compiled

  def compile(scheme) when is_atom(scheme) do
    specs = Enum.map(scheme.layers(), &normalize_layer(&1, scheme))
    names = Enum.map(specs, & &1.name)

    if length(Enum.uniq(names)) != length(names) do
      raise ArgumentError, "#{inspect(scheme)} declares a layer more than once: #{inspect(names)}"
    end

    Enum.each(specs, fn spec ->
      Enum.each(spec.ops, fn
        {_op, reach} when is_list(reach) ->
          unknown = reach -- names

          if unknown != [] do
            raise ArgumentError,
                  "#{inspect(scheme)} layer #{inspect(spec.name)} reaches undeclared layers " <>
                    inspect(unknown)
          end

        _ ->
          :ok
      end)
    end)

    %{
      module: scheme,
      names: names,
      specs: Map.new(specs, &{&1.name, &1}),
      ranks: names |> Enum.with_index(1) |> Map.new(),
      precedence: normalize_precedence(scheme.precedence())
    }
  end

  defp normalize_layer(layer, scheme) do
    layer = Map.new(layer)
    name = Map.get(layer, :name) || raise ArgumentError, "#{inspect(scheme)}: a layer needs :name"

    ops =
      layer
      |> Map.get(:ops, [])
      |> Enum.map(fn
        {op, reach} -> {op, reach}
        op when is_atom(op) -> {op, :any}
      end)
      |> Map.new()

    Enum.each(ops, fn {op, reach} ->
      unless op in @ops do
        raise ArgumentError,
              "#{inspect(scheme)} layer #{inspect(name)}: unknown op #{inspect(op)}"
      end

      unless reach in @reaches or is_list(reach) do
        raise ArgumentError,
              "#{inspect(scheme)} layer #{inspect(name)}: unknown reach #{inspect(reach)}"
      end
    end)

    %{
      name: name,
      ops: ops,
      protected: Map.get(layer, :protected, []),
      scope_key: Map.get(layer, :scope_key)
    }
  end

  defp normalize_precedence(precedence) do
    precedence = Map.new(precedence)

    %{
      declarations: Map.get(precedence, :declarations, :outer_wins),
      edits: Map.get(precedence, :edits, :cascade),
      refusals: Map.get(precedence, :refusals, :all)
    }
  end

  # --- queries ----------------------------------------------------------------------

  @doc "Layer names, outermost first."
  @spec layers(module() | compiled()) :: [layer()]
  def layers(scheme), do: compile(scheme).names

  @doc "1-based rank of `layer` (1 is outermost), or `nil` if the scheme does not declare it."
  @spec rank(module() | compiled(), layer()) :: pos_integer() | nil
  def rank(scheme, layer), do: Map.get(compile(scheme).ranks, layer)

  @doc "True if layer `a` outranks (is outer to) layer `b`."
  @spec outranks?(module() | compiled(), layer(), layer()) :: boolean()
  def outranks?(scheme, a, b), do: rank(scheme, a) < rank(scheme, b)

  @doc "The normalized declaration of `layer`, or `nil`."
  @spec spec(module() | compiled(), layer()) :: layer_spec() | nil
  def spec(scheme, layer), do: Map.get(compile(scheme).specs, layer)

  @doc "The normalized precedence semantics."
  @spec precedence(module() | compiled()) :: precedence()
  def precedence(scheme), do: compile(scheme).precedence

  @doc "True if a contribution at `layer` may perform `op` at all."
  @spec allows?(module() | compiled(), layer(), op()) :: boolean()
  def allows?(scheme, layer, op) do
    case spec(scheme, layer) do
      nil -> false
      spec -> Map.has_key?(spec.ops, op)
    end
  end

  @doc "True if rules declared at `target` refuse `op` whatever the editor's reach."
  @spec protected?(module() | compiled(), layer(), op()) :: boolean()
  def protected?(scheme, target, op) do
    case spec(scheme, target) do
      nil -> false
      spec -> op in spec.protected
    end
  end

  @doc "True if `op` performed at `editor` may touch a rule declared at `target`."
  @spec reaches?(module() | compiled(), layer(), op(), layer()) :: boolean()
  def reaches?(scheme, editor, op, target) do
    scheme = compile(scheme)

    with %{ops: ops} <- spec(scheme, editor),
         {:ok, reach} <- Map.fetch(ops, op),
         editor_rank when is_integer(editor_rank) <- rank(scheme, editor),
         target_rank when is_integer(target_rank) <- rank(scheme, target) do
      reach?(reach, editor_rank, target_rank, target)
    else
      _ -> false
    end
  end

  defp reach?(:any, _e, _t, _target), do: true
  defp reach?(:outer, e, t, _target), do: t < e
  defp reach?(:self_and_outer, e, t, _target), do: t <= e
  defp reach?(:inner, e, t, _target), do: t > e
  defp reach?(:self_and_inner, e, t, _target), do: t >= e
  defp reach?(layers, _e, _t, target) when is_list(layers), do: target in layers

  # --- default implementations ------------------------------------------------------

  @doc "The default scope match (see the moduledoc)."
  @spec default_scope_matches?(scope(), context()) :: boolean()
  def default_scope_matches?(nil, _context), do: true
  def default_scope_matches?(scope, _context) when map_size(scope) == 0, do: true

  def default_scope_matches?(scope, context) when is_map(scope) do
    context = context || %{}

    Enum.all?(scope, fn {key, wanted} ->
      case Map.fetch(context, key) do
        {:ok, have} ->
          have = List.wrap(have)
          Enum.any?(List.wrap(wanted), &(&1 in have))

        :error ->
          false
      end
    end)
  end

  @doc """
  The default strictly-stronger check:

    * `:at_least` — a minimum: higher is stronger (numbers and `Decimal`s).
    * `:at_most` — a maximum: lower is stronger.
    * `:superset` — a list/set requirement: a strict superset is stronger.
    * `{:ranked, [weakest, ..., strongest]}` — later in the list is stronger.

  Equal is never stronger; incomparable values are never stronger.
  """
  @spec default_stronger?(direction(), term(), term()) :: boolean()
  def default_stronger?(:at_least, current, proposed), do: compare(proposed, current) == :gt
  def default_stronger?(:at_most, current, proposed), do: compare(proposed, current) == :lt

  def default_stronger?(:superset, current, proposed)
      when is_list(current) and is_list(proposed) do
    current = MapSet.new(current)
    proposed = MapSet.new(proposed)
    MapSet.subset?(current, proposed) and not MapSet.equal?(current, proposed)
  end

  def default_stronger?({:ranked, order}, current, proposed) when is_list(order) do
    with c when is_integer(c) <- Enum.find_index(order, &(&1 == current)),
         p when is_integer(p) <- Enum.find_index(order, &(&1 == proposed)) do
      p > c
    else
      _ -> false
    end
  end

  def default_stronger?(_direction, _current, _proposed), do: false

  defp compare(a, b) when is_number(a) and is_number(b) do
    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  defp compare(a, b) do
    with {:ok, a} <- to_decimal(a), {:ok, b} <- to_decimal(b) do
      Decimal.compare(a, b)
    else
      _ -> :incomparable
    end
  end

  defp to_decimal(%Decimal{} = d), do: {:ok, d}
  defp to_decimal(i) when is_integer(i), do: {:ok, Decimal.new(i)}
  defp to_decimal(f) when is_float(f), do: {:ok, Decimal.from_float(f)}
  defp to_decimal(_), do: :error

  @doc "Generic refusal messages, used unless a scheme overrides `c:refusal_message/4`."
  @spec default_refusal_message(refusal_reason(), map(), map() | nil, map()) :: String.t()
  def default_refusal_message(reason, contribution, target, detail) do
    op = contribution.op
    rule = inspect(contribution.rule_id)
    layer = inspect(contribution.layer)
    target_layer = target && inspect(target.layer)

    case reason do
      :unknown_layer ->
        "#{op} of rule #{rule} declares layer #{layer}, which the scheme does not declare"

      :unknown_op ->
        "#{inspect(op)} of rule #{rule} is not a layering operation"

      :unscoped ->
        "#{op} of rule #{rule} at layer #{layer} carries no #{inspect(detail[:scope_key])} " <>
          "scope; an unscoped contribution there would apply everywhere"

      :op_not_allowed ->
        "layer #{layer} may not #{op} (rule #{rule})"

      :blank_replacement ->
        "replacement for rule #{rule} carries no replacement rules"

      :undeclared ->
        "#{op} of rule #{rule} targets a rule no applicable layer declares"

      :protected ->
        "#{op} of rule #{rule} refused: it is declared in the #{target_layer} layer, " <>
          "which refuses #{op}"

      :out_of_reach ->
        "#{op} of rule #{rule} refused: layer #{layer} may not #{op} rules declared in the " <>
          "#{target_layer} layer"

      :replacement_invalid ->
        "replacement rules for #{rule} do not decode: " <>
          Enum.join(List.wrap(detail[:errors]), "; ")

      :already_declared ->
        "add of rule #{rule} at layer #{layer} refused: the #{target_layer} layer already " <>
          "declares it differently; use :tighten to strengthen it"

      :nothing_to_tighten ->
        "#{op} of rule #{rule} refused: it supplies no params"

      :unknown_param ->
        "#{op} of rule #{rule} refused: the rule declares no param #{inspect(detail[:param])}"

      :no_direction ->
        "#{op} of rule #{rule} refused: param #{inspect(detail[:param])} declares no " <>
          "strength direction, so stronger cannot be judged"

      :not_stronger ->
        "#{op} of rule #{rule} at layer #{layer} refused: #{inspect(detail[:param])} " <>
          "#{inspect(detail[:proposed])} is not strictly stronger than " <>
          "#{inspect(detail[:current])} (#{inspect(detail[:direction])})"

      :unbound_param ->
        "rule #{rule} references param #{inspect(detail[:param])}, which no contribution binds"
    end
  end

  # --- params ---------------------------------------------------------------------------

  @doc """
  A param placeholder for a predicate value in an `AshRules.Ir.Rule`. The
  resolver binds it to the rule's effective param, so the threshold lands in
  the rule IR and therefore in the bundle's content hash:

      neg(:vendor, :gl_coverage_at_least, AshCompliance.Layering.param(:min_amount))

  JSON-stored rules spell it `%{"param" => "min_amount"}`.
  """
  @spec param(atom()) :: {:param, atom()}
  def param(name) when is_atom(name), do: {:param, name}

  @doc "The param name a predicate value refers to, or `nil`."
  @spec param_ref(term()) :: atom() | String.t() | nil
  def param_ref({:param, name}) when is_atom(name) or is_binary(name), do: name
  def param_ref(%{"param" => name}) when is_binary(name), do: name
  def param_ref(_), do: nil

  @doc "True if any predicate of `rule` carries a param placeholder."
  @spec parameterized?(Rule.t()) :: boolean()
  def parameterized?(%Rule{} = rule) do
    rule |> Rule.predicates() |> Enum.any?(&(param_ref(&1.value) != nil))
  end

  @doc "All operations the vocabulary knows."
  @spec ops() :: [op(), ...]
  def ops, do: @ops
end
