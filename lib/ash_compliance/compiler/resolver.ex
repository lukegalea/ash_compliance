# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Compiler.Resolver do
  @moduledoc """
  The pure merge behind `AshCompliance.Compiler.resolve/3`: contributions in,
  `AshCompliance.Compiler.Resolution` out. No database, no clock, no
  application env — everything it knows arrives as arguments.

  See `AshCompliance.Compiler.resolve/3` for the contribution shape and
  `AshCompliance.Layering` for what a scheme declares.
  """

  alias AshCompliance.Compiler.Resolution
  alias AshCompliance.Layering
  alias AshRules.Ir.Rule

  @doc "Resolves `contributions` under `scheme` for `context`."
  @spec resolve([map()], module(), Layering.context() | nil) :: Resolution.t()
  def resolve(contributions, scheme, context \\ %{}) do
    scheme = Layering.compile(scheme)
    context = context || %{}
    contributions = Enum.map(contributions, &normalize/1)

    base = %Resolution{scheme: scheme.module, context: context}

    case admit(contributions, scheme, context) do
      {:halt, refusals} ->
        %{base | refusals: refusals}

      {:ok, admitted, refusals} ->
        case scheme.precedence.edits do
          :against_declarations -> against_declarations(admitted, scheme, refusals, base)
          :cascade -> cascade(admitted, scheme, refusals, base)
        end
    end
  end

  # --- normalization and admission ------------------------------------------------

  @defaults %{
    op: :add,
    rule_id: nil,
    rule: nil,
    rules: nil,
    layer: nil,
    scope: nil,
    params: %{},
    strength: %{},
    combining: :deny_overrides,
    source_id: nil,
    source: nil,
    severity: nil,
    message: nil
  }

  defp normalize(contribution) do
    contribution = Map.merge(@defaults, Map.new(contribution))
    rule_id = contribution.rule_id || (contribution.rule && contribution.rule.id)

    %{
      contribution
      | rule_id: rule_id,
        params: contribution.params || %{},
        strength: contribution.strength || %{},
        combining: contribution.combining || :deny_overrides
    }
  end

  # Structural refusals come first (a malformed or unscoped contribution is
  # refused whatever the context); then the scope filter drops contributions
  # that do not apply here. Dropped is not refused: a job-scoped removal is
  # simply invisible to a PMC-level read.
  defp admit(contributions, scheme, context) do
    first? = scheme.precedence.refusals == :first

    Enum.reduce_while(contributions, {:ok, [], []}, fn c, {:ok, admitted, refusals} ->
      case structural_check(c, scheme) do
        :ok ->
          if scheme.module.scope_matches?(c.scope, context) do
            {:cont, {:ok, [c | admitted], refusals}}
          else
            {:cont, {:ok, admitted, refusals}}
          end

        {:refuse, refusal} ->
          if first?,
            do: {:halt, {:halt, [refusal]}},
            else: {:cont, {:ok, admitted, [refusal | refusals]}}
      end
    end)
    |> case do
      {:halt, refusals} -> {:halt, refusals}
      {:ok, admitted, refusals} -> {:ok, Enum.reverse(admitted), Enum.reverse(refusals)}
    end
  end

  defp structural_check(c, scheme) do
    spec = Layering.spec(scheme, c.layer)

    cond do
      c.op not in Layering.ops() ->
        refuse(:unknown_op, c, nil, scheme)

      is_nil(spec) ->
        refuse(:unknown_layer, c, nil, scheme)

      spec.scope_key && not scoped_by?(c.scope, spec.scope_key) ->
        refuse(:unscoped, c, nil, scheme, %{scope_key: spec.scope_key})

      c.op == :add and not Layering.allows?(scheme, c.layer, :add) ->
        refuse(:op_not_allowed, c, nil, scheme)

      true ->
        :ok
    end
  end

  defp scoped_by?(scope, key) when is_map(scope), do: Map.get(scope, key) not in [nil, []]
  defp scoped_by?(_scope, _key), do: false

  # --- :against_declarations ---------------------------------------------------------

  # Every add is collected first; each edit is then checked, in the order the
  # source supplied, against the winning declaration. Edits do not see one
  # another (except successive tightens of one rule, which compound).
  defp against_declarations(admitted, scheme, refusals, base) do
    {adds, edits} = Enum.split_with(admitted, &(&1.op == :add))
    first? = scheme.precedence.refusals == :first

    acc = %{exclusions: [], groups: [], accepted: [], params: %{}, refusals: refusals}

    acc =
      Enum.reduce_while(edits, acc, fn edit, acc ->
        target = winner(adds, edit.rule_id, scheme)
        current = Map.get(acc.params, edit.rule_id, target && target.params)

        case check(edit, target, current, scheme) do
          {:ok, effect} ->
            {:cont, accept_against(effect, edit, acc)}

          {:refuse, refusal} ->
            acc = %{acc | refusals: acc.refusals ++ [refusal]}
            if first?, do: {:halt, acc}, else: {:cont, acc}
        end
      end)

    # Replacement groups join the declarations most-recent-first: on a tie
    # between two replacements of the same id, the later grant stands.
    all = adds ++ (acc.groups |> Enum.reverse() |> Enum.concat())
    excluded_ids = MapSet.new(acc.exclusions, & &1.rule_id)

    winners =
      all
      |> Enum.group_by(& &1.rule_id)
      |> Enum.map(fn {_rule_id, group} -> pick(group, scheme) end)
      |> Enum.reject(&MapSet.member?(excluded_ids, &1.rule_id))
      |> Enum.map(fn winner ->
        edits = Enum.filter(acc.accepted, &(&1.rule_id == winner.rule_id))
        winner = Enum.reduce(edits, winner, &apply_edit/2)
        winner = %{winner | params: Map.get(acc.params, winner.rule_id, winner.params)}
        Map.put(winner, :steps, [step(winner) | Enum.map(edits, &step/1)])
      end)

    finish(%{
      base
      | winners: winners,
        excluded: acc.exclusions,
        refusals: acc.refusals,
        declarations: adds,
        replacements: Enum.concat(acc.groups)
    })
    |> with_combining(scheme)
  end

  defp accept_against({:exclude, _}, edit, acc),
    do: %{acc | exclusions: acc.exclusions ++ [step(edit)]}

  defp accept_against({:replace, rules}, edit, acc),
    do: %{acc | groups: acc.groups ++ [replacement_contributions(rules, edit)]}

  defp accept_against({:params, params}, edit, acc),
    do: %{
      acc
      | params: Map.put(acc.params, edit.rule_id, params),
        accepted: acc.accepted ++ [edit]
    }

  defp accept_against(:refine, edit, acc), do: %{acc | accepted: acc.accepted ++ [edit]}

  defp winner(adds, rule_id, scheme) do
    case Enum.filter(adds, &(&1.rule_id == rule_id)) do
      [] -> nil
      group -> pick(group, scheme)
    end
  end

  defp pick(group, %{precedence: %{declarations: :inner_wins}} = scheme),
    do: Enum.max_by(group, &Layering.rank(scheme, &1.layer))

  defp pick(group, scheme), do: Enum.min_by(group, &Layering.rank(scheme, &1.layer))

  # --- :cascade -------------------------------------------------------------------------

  # Contributions apply outermost layer first (stable within a layer), each
  # against the result so far.
  defp cascade(admitted, scheme, refusals, base) do
    first? = scheme.precedence.refusals == :first

    sorted =
      admitted
      |> Enum.with_index()
      |> Enum.sort_by(fn {c, index} -> {Layering.rank(scheme, c.layer), index} end)
      |> Enum.map(&elem(&1, 0))

    acc = %{effective: %{}, excluded: [], replacements: [], refusals: refusals}

    acc =
      Enum.reduce_while(sorted, acc, fn c, acc ->
        case cascade_one(c, acc, scheme) do
          {:ok, acc} ->
            {:cont, acc}

          {:refuse, refusal} ->
            acc = %{acc | refusals: acc.refusals ++ [refusal]}
            if first?, do: {:halt, acc}, else: {:cont, acc}
        end
      end)

    finish(%{
      base
      | winners: Map.values(acc.effective),
        excluded: acc.excluded,
        refusals: acc.refusals,
        declarations: Enum.filter(admitted, &(&1.op == :add)),
        replacements: acc.replacements
    })
    |> with_combining(scheme)
  end

  defp cascade_one(%{op: :add} = c, acc, scheme) do
    case Map.fetch(acc.effective, c.rule_id) do
      :error ->
        {:ok, put_effective(acc, Map.put(c, :steps, [step(c)]))}

      {:ok, existing} ->
        cond do
          existing.rule == c.rule and existing.params == c.params ->
            {:ok, put_effective(acc, %{existing | steps: existing.steps ++ [step(c)]})}

          scheme.precedence.declarations == :inner_wins ->
            {:ok, put_effective(acc, Map.put(c, :steps, existing.steps ++ [step(c)]))}

          true ->
            refuse(:already_declared, c, existing, scheme)
        end
    end
  end

  defp cascade_one(c, acc, scheme) do
    target = Map.get(acc.effective, c.rule_id)

    case check(c, target, target && target.params, scheme) do
      {:ok, {:exclude, _}} ->
        {:ok,
         %{
           acc
           | effective: Map.delete(acc.effective, c.rule_id),
             excluded: acc.excluded ++ [step(c)]
         }}

      {:ok, {:params, params}} ->
        updated = %{target | params: params, steps: target.steps ++ [step(c)]}
        {:ok, put_effective(acc, updated)}

      {:ok, :refine} ->
        updated = apply_edit(c, target)
        {:ok, put_effective(acc, %{updated | steps: target.steps ++ [step(c)]})}

      {:ok, {:replace, rules}} ->
        replacements = replacement_contributions(rules, c)
        effective = Map.delete(acc.effective, c.rule_id)

        case Enum.find(replacements, &Map.has_key?(effective, &1.rule_id)) do
          nil ->
            effective =
              Enum.reduce(replacements, effective, fn r, effective ->
                Map.put(effective, r.rule_id, Map.put(r, :steps, [step(r)]))
              end)

            {:ok, %{acc | effective: effective, replacements: acc.replacements ++ replacements}}

          clash ->
            refuse(:already_declared, clash, Map.fetch!(effective, clash.rule_id), scheme)
        end

      {:refuse, _} = refused ->
        refused
    end
  end

  defp put_effective(acc, entry),
    do: %{acc | effective: Map.put(acc.effective, entry.rule_id, entry)}

  # --- shared checks ------------------------------------------------------------------

  defp check(c, target, current_params, scheme) do
    cond do
      not Layering.allows?(scheme, c.layer, c.op) ->
        refuse(:op_not_allowed, c, target, scheme)

      c.op == :replace and is_nil(c.rules) ->
        refuse(:blank_replacement, c, target, scheme)

      is_nil(target) ->
        refuse(:undeclared, c, nil, scheme)

      Layering.protected?(scheme, target.layer, c.op) ->
        refuse(:protected, c, target, scheme)

      not Layering.reaches?(scheme, c.layer, c.op, target.layer) ->
        refuse(:out_of_reach, c, target, scheme)

      true ->
        check_op(c, target, current_params || %{}, scheme)
    end
  end

  defp check_op(%{op: op}, _target, _params, _scheme) when op in [:exclude, :waive],
    do: {:ok, {:exclude, op}}

  defp check_op(%{op: :refine}, _target, _params, _scheme), do: {:ok, :refine}

  defp check_op(%{op: :replace, rules: {:error, errors}} = c, target, _params, scheme),
    do: refuse(:replacement_invalid, c, target, scheme, %{errors: errors})

  defp check_op(%{op: :replace, rules: rules}, _target, _params, _scheme) when is_list(rules),
    do: {:ok, {:replace, rules}}

  defp check_op(%{op: :parameterize} = c, _target, params, _scheme),
    do: {:ok, {:params, Map.merge(params, c.params)}}

  defp check_op(%{op: :tighten, params: proposed} = c, target, _params, scheme)
       when map_size(proposed) == 0,
       do: refuse(:nothing_to_tighten, c, target, scheme)

  defp check_op(%{op: :tighten} = c, target, params, scheme) do
    Enum.reduce_while(c.params, {:ok, {:params, params}}, fn {param, proposed},
                                                             {:ok, {:params, acc}} ->
      direction = Map.get(target.strength, param)

      cond do
        not Map.has_key?(acc, param) ->
          {:halt, refuse(:unknown_param, c, target, scheme, %{param: param})}

        is_nil(direction) ->
          {:halt, refuse(:no_direction, c, target, scheme, %{param: param})}

        not scheme.module.stronger?(direction, Map.fetch!(acc, param), proposed) ->
          detail = %{
            param: param,
            current: Map.fetch!(acc, param),
            proposed: proposed,
            direction: direction
          }

          {:halt, refuse(:not_stronger, c, target, scheme, detail)}

        true ->
          {:cont, {:ok, {:params, Map.put(acc, param, proposed)}}}
      end
    end)
  end

  defp apply_edit(%{op: :refine} = edit, winner) do
    rule = %{winner.rule | severity: edit.severity || winner.rule.severity}
    rule = %{rule | message: edit.message || rule.message}
    %{winner | rule: rule}
  end

  defp apply_edit(_edit, winner), do: winner

  defp replacement_contributions(rules, edit) do
    Enum.map(rules, fn rule ->
      %{
        edit
        | op: :add,
          rule_id: rule.id,
          rule: rule,
          rules: nil,
          params: %{},
          strength: %{},
          severity: nil,
          message: nil
      }
      |> Map.put(:via, :replace)
    end)
  end

  # --- finishing -------------------------------------------------------------------------

  defp finish(%Resolution{} = resolution) do
    {winners, unbound} =
      Enum.map_reduce(resolution.winners, [], fn winner, unbound ->
        case bind(winner) do
          {:ok, winner} -> {winner, unbound}
          {:error, refusals} -> {winner, unbound ++ refusals}
        end
      end)

    scheme = resolution.scheme

    unbound =
      Enum.map(unbound, fn {winner, param} ->
        build_refusal(:unbound_param, winner, nil, scheme, %{param: param})
      end)

    %{
      resolution
      | winners: winners,
        rules: winners |> Enum.map(& &1.rule) |> Enum.sort_by(& &1.id),
        params: Map.new(winners, &{&1.rule_id, &1.params}),
        lineage: Map.new(winners, &{&1.rule_id, Map.get(&1, :steps, [])}),
        refusals: resolution.refusals ++ unbound
    }
  end

  defp with_combining(%Resolution{winners: []} = resolution, _scheme),
    do: %{resolution | combining: AshRules.Combining.default()}

  defp with_combining(%Resolution{winners: winners} = resolution, scheme) do
    sign = if scheme.precedence.declarations == :inner_wins, do: -1, else: 1

    combining =
      winners
      |> Enum.min_by(&{sign * Layering.rank(scheme, &1.layer), &1.rule_id})
      |> Map.get(:combining)

    %{resolution | combining: combining}
  end

  # Param placeholders in predicate values are bound to the effective params,
  # so a threshold is part of the rule IR and therefore of the bundle hash.
  defp bind(%{rule: %Rule{} = rule} = winner) do
    if Layering.parameterized?(rule) do
      {applicability, missing_a} = bind_predicates(rule.applicability, winner.params)
      {failures, missing_f} = bind_predicates(rule.failure_conditions, winner.params)

      case Enum.uniq(missing_a ++ missing_f) do
        [] ->
          {:ok,
           %{winner | rule: %{rule | applicability: applicability, failure_conditions: failures}}}

        missing ->
          {:error, Enum.map(missing, &{winner, &1})}
      end
    else
      {:ok, winner}
    end
  end

  defp bind(winner), do: {:ok, winner}

  defp bind_predicates(predicates, params) do
    Enum.map_reduce(predicates, [], fn predicate, missing ->
      case Layering.param_ref(predicate.value) do
        nil ->
          {predicate, missing}

        name ->
          case fetch_param(params, name) do
            {:ok, value} -> {%{predicate | value: value}, missing}
            :error -> {predicate, missing ++ [name]}
          end
      end
    end)
  end

  defp fetch_param(params, name) do
    key = to_string(name)

    case Enum.find(params, fn {k, _v} -> to_string(k) == key end) do
      {_k, value} -> {:ok, value}
      nil -> :error
    end
  end

  # --- steps and refusals -----------------------------------------------------------------

  defp step(c) do
    %{
      rule_id: c.rule_id,
      op: Map.get(c, :via, c.op),
      layer: c.layer,
      source_id: c.source_id,
      source: c.source,
      scope: c.scope,
      params: c.params
    }
  end

  defp refuse(reason, c, target, scheme, detail \\ %{}),
    do: {:refuse, build_refusal(reason, c, target, scheme, detail)}

  defp build_refusal(reason, c, target, scheme, detail) do
    module = if is_atom(scheme), do: scheme, else: scheme.module

    %{
      reason: reason,
      message: module.refusal_message(reason, c, target, detail),
      rule_id: c.rule_id,
      op: c.op,
      layer: c.layer,
      source_id: c.source_id,
      source: c.source,
      detail: detail
    }
  end
end
