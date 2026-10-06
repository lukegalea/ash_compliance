# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Compiler do
  @moduledoc """
  Resolves catalog, profile and tenant layers into the effective
  `AshRules.Ir.Bundle`, through the fixed layering precedence.

  The precedence is fixed by `AshCompliance.Compiler.Layer` — non-waivable
  global > global mandatory > profile refinements > tenant strengthening >
  approved replacements/waivers > tenant supplements — and it is not
  negotiable at compile time: there is no API here that accepts a custom
  layer order, an ad-hoc inheritance chain, or a caller-provided rule list.
  Contributions come from `RuleSetRevision`, `ProfileRevision` and
  `PolicyOverride` rows only.

  On conflict (same rule id), the lowest-rank layer wins, and overreach is
  refused loudly: replacements may only displace tenant supplements, waivers
  cannot target non-waivable globals, profile excludes and refines cannot
  touch rules that outrank the refinement layer.

  An explicit combining algorithm travels with each layer (default
  `deny_overrides`); the effective bundle carries the algorithm of the
  highest-precedence layer that contributed a winning rule.

  Waivers are bounded-time artifacts evaluated against the compile clock:
  expired waivers are excluded from resolution entirely, so a waiver lapsing
  returns its rule to the effective bundle without any action being taken.

  Output is a fully validated `AshRules.Ir.Bundle`, a lineage list of the
  contributions actually included, and the manifest revision string the
  compiled `PolicyBundle` stores.
  """

  alias AshCompliance.Compiler.Layer
  alias AshCompliance.Domain

  alias AshRules.Ir
  alias AshRules.Ir.Bundle
  alias AshRules.Verifier

  @typedoc "One resolved contribution: a rule at a layer, from a source."
  @type contribution :: %{
          required(:rule_id) => String.t(),
          required(:rule) => AshRules.Ir.Rule.t(),
          required(:layer) => Layer.t(),
          required(:combining) => AshRules.Combining.algorithm(),
          required(:source_id) => String.t() | nil,
          required(:source) => String.t()
        }

  @typedoc "What the compile actually did — stored on the PolicyBundle as data."
  @type lineage_entry :: %{
          required(:layer) => Layer.t(),
          required(:source) => String.t(),
          required(:revision_id) => String.t() | nil,
          required(:effect) => :included | :excluded_by_waiver | :replaced,
          required(:rule_count) => non_neg_integer()
        }

  @doc """
  Compiles the effective bundle for an organization.

  Options:

    * `:organization_id` — required
    * `:now` — the compile clock (defaults to now, truncated to seconds);
      waiver expiry is evaluated against it, and tests pin it for determinism

  Returns `{:ok, bundle, lineage}` or `{:error, errors}`.
  """
  @spec compile(keyword()) ::
          {:ok, Bundle.t(), [lineage_entry()]} | {:error, String.t() | [String.t()]}
  def compile(opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    now = Keyword.get(opts, :now) || DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, inputs} <- gather(organization_id, now),
         {:ok, contributions, schema} <- decode_sources(inputs),
         {:ok, exclusions, replacements, refusals} <-
           apply_overrides(inputs.overrides, contributions),
         :ok <- check_refusals(refusals),
         {:ok, exclusions, refusals} <-
           apply_profile_operations(inputs.profile_revisions, contributions, exclusions, refusals),
         :ok <- check_refusals(refusals) do
      {rules, combining, lineage} = merge(contributions, replacements, exclusions, inputs)

      case Verifier.verify(schema, rules) do
        :ok ->
          bundle =
            Bundle.new(rules, schema,
              revision: manifest_revision(inputs, lineage),
              fact_schema_revision: manifest_revision(inputs, lineage),
              combining: combining
            )

          {:ok, bundle, lineage}

        {:error, errors} ->
          {:error, errors}
      end
    end
  end

  # --- gathering ---------------------------------------------------------------

  # Trusted machinery: the compile is a headless system operation (the
  # PolicyBundle compile action, a host console, a worker) — no user request
  # is attached, so these reads run under `authorize?: false` on purpose.
  # Host-facing entry points thread `actor:`/`authorize?:` instead (see
  # `AshCompliance.Oscal` and `AshCompliance.Testing`).
  defp gather(organization_id, now) do
    {:ok,
     %{
       organization_id: organization_id,
       now: now,
       rule_sets: active_rule_sets(organization_id),
       profile_revisions: profile_revisions(organization_id),
       overrides: valid_overrides(organization_id, now)
     }}
  end

  defp active_rule_sets(organization_id) do
    Domain.active_rule_set_revisions!(organization_id, authorize?: false)
  end

  defp profile_revisions(organization_id) do
    # Absence is meaningful: no tenant policy set yet means no tailoring, so
    # the action carries not_found_error?: false and yields {:ok, nil}.
    {:ok, policy_set} = Domain.tenant_policy_set(organization_id, authorize?: false)

    case policy_set do
      nil ->
        []

      policy_set ->
        Enum.map(policy_set.profile_revision_ids, fn id ->
          Domain.get_profile_revision_by_id!(id, authorize?: false)
        end)
    end
  end

  defp valid_overrides(organization_id, now) do
    Domain.valid_policy_overrides!(organization_id, now, authorize?: false)
  end

  # --- decoding ------------------------------------------------------------------

  # Every active rule set revision contributes its rules at its layer. The
  # fact schemas of all sources are merged; duplicate predicates must agree
  # on type and semantics or the compile is refused.
  defp decode_sources(inputs) do
    sources =
      Enum.map(inputs.rule_sets, fn revision ->
        {revision.id, revision.name, revision.layer, revision.combining, revision.rules_json}
      end)

    decoded =
      Enum.map(sources, fn {id, name, layer, combining, json} ->
        case Ir.decode(json) do
          {:ok, bundle} -> {:ok, {id, name, layer, combining, bundle}}
          {:error, errors} -> {:error, name, errors}
        end
      end)

    errors =
      for {:error, name, errors} <- decoded,
          error <- List.wrap(errors) do
        "rule set #{inspect(name)} does not decode: #{error}"
      end

    if errors != [] do
      {:error, errors}
    else
      contributions =
        Enum.flat_map(decoded, fn {:ok, {id, name, layer, combining, bundle}} ->
          Enum.map(bundle.rules, fn rule ->
            %{
              rule_id: rule.id,
              rule: rule,
              layer: layer,
              combining: combining,
              source_id: id,
              source: name
            }
          end)
        end)

      bundles = Enum.map(decoded, fn {:ok, {_, _, _, _, bundle}} -> bundle end)

      with {:ok, schema} <- merge_fact_schemas(bundles) do
        {:ok, contributions, schema}
      end
    end
  end

  defp merge_fact_schemas(bundles) do
    facts =
      bundles
      |> Enum.flat_map(& &1.fact_schema.facts)
      |> Enum.group_by(& &1.name)
      |> Enum.map(fn {_name, same_name} ->
        same_name
        |> Enum.uniq_by(&{&1.type, &1.one_of, &1.missing, &1.cardinality})
        |> case do
          [fact] -> fact
          _conflicting -> :conflict
        end
      end)

    if Enum.any?(facts, &(&1 == :conflict)) do
      {:error,
       "contributing rule sets declare the same fact with conflicting types or absence semantics"}
    else
      {:ok, AshRules.Ir.FactSchema.new(facts)}
    end
  end

  # --- overrides -------------------------------------------------------------------

  defp apply_overrides(overrides, contributions) do
    Enum.reduce_while(overrides, {:ok, [], [], []}, fn
      override, {:ok, exclusions, replacements, refusals} ->
        case check_override(override, contributions) do
          {:waive, rule_id} ->
            {:cont, {:ok, [rule_id | exclusions], replacements, refusals}}

          {:replace, replacement_contributions} ->
            {:cont, {:ok, exclusions, replacement_contributions ++ replacements, refusals}}

          {:refuse, message} ->
            {:halt, {:error, [message | refusals]}}
        end
    end)
  end

  defp check_override(override, contributions) do
    winner = winning_contribution(contributions, override.rule_id)

    cond do
      override.kind == :waive and is_nil(winner) ->
        {:refuse,
         "waiver for rule #{inspect(override.rule_id)} targets a rule no active layer declares"}

      override.kind == :waive and not Layer.waivable?(winner.layer) ->
        {:refuse,
         "waiver for rule #{inspect(override.rule_id)} refused: the rule is declared in the " <>
           "non-waivable global layer and can never be waived"}

      override.kind == :waive ->
        {:waive, override.rule_id}

      blank?(override.replacement_rules_json) ->
        {:refuse,
         "replacement for rule #{inspect(override.rule_id)} carries no replacement rule set"}

      is_nil(winner) ->
        {:refuse,
         "replacement for rule #{inspect(override.rule_id)} targets a rule no active layer declares"}

      not Layer.replaceable?(winner.layer) ->
        {:refuse,
         "replacement for rule #{inspect(override.rule_id)} refused: it is declared in the " <>
           "#{layer_name(winner)} layer, which outranks approved overrides. Only tenant " <>
           "supplements can be replaced"}

      true ->
        case Ir.decode(override.replacement_rules_json) do
          {:ok, bundle} ->
            {:replace,
             Enum.map(bundle.rules, fn rule ->
               %{
                 rule_id: rule.id,
                 rule: rule,
                 layer: Layer.override_layer(),
                 combining: :deny_overrides,
                 source_id: override.id,
                 source: "override:#{override.id}"
               }
             end)}

          {:error, errors} ->
            {:refuse,
             "replacement rule set for #{inspect(override.rule_id)} does not decode: " <>
               (List.wrap(errors) |> Enum.join("; "))}
        end
    end
  end

  # The cond above refuses on `is_nil(winner)` before this is reached, so no
  # nil clause is needed (a dead one warns under --warnings-as-errors).
  defp layer_name(contribution), do: inspect(contribution.layer)

  # --- profile operations ---------------------------------------------------------

  defp apply_profile_operations(profile_revisions, contributions, exclusions, refusals) do
    profile_revisions
    |> Enum.flat_map(fn revision ->
      # Operations round-trip through JSONB storage (string keys/values);
      # normalize back to the atom-keyed form before use.
      Enum.map(revision.operations, fn operation ->
        {:ok, normalized} = AshCompliance.Oscal.ProfileOperation.normalize(operation)
        normalized
      end)
    end)
    |> Enum.reduce_while({:ok, exclusions, refusals}, fn operation, {:ok, exclusions, refusals} ->
      case apply_profile_operation(operation, contributions) do
        {:exclude, rule_id} ->
          {:cont, {:ok, [rule_id | exclusions], refusals}}

        :refine ->
          {:cont, {:ok, exclusions, refusals}}

        :documentary ->
          {:cont, {:ok, exclusions, refusals}}

        {:refuse, message} ->
          {:halt, {:error, exclusions, [message | refusals]}}
      end
    end)
    |> case do
      {:ok, exclusions, refusals} -> {:ok, Enum.uniq(exclusions), refusals}
      {:error, _exclusions, refusals} -> {:error, refusals}
    end
  end

  defp apply_profile_operation(operation, contributions) do
    target = operation[:target]

    case operation.op do
      op when op in [:include, :supplement] ->
        :documentary

      :parameterize ->
        {:refuse,
         "profile parameterizes #{inspect(target)}: the rule IR has no parameter binding in " <>
           "v1 — precompute parameterized facts instead"}

      :exclude ->
        rank = winning_rank(contributions, target)

        cond do
          is_nil(rank) ->
            {:refuse, "profile excludes rule #{inspect(target)}, which no active layer declares"}

          rank <= Layer.rank(:profile_refinement) ->
            {:refuse,
             "profile cannot exclude rule #{inspect(target)}: it is declared in a layer that " <>
               "outranks profile refinements"}

          true ->
            {:exclude, target}
        end

      :refine ->
        rank = winning_rank(contributions, target)

        cond do
          is_nil(rank) ->
            {:refuse, "profile refines rule #{inspect(target)}, which no active layer declares"}

          rank <= Layer.rank(:global_mandatory) ->
            {:refuse,
             "profile cannot refine rule #{inspect(target)}: it is declared in a mandatory " <>
               "layer that outranks profile refinements"}

          true ->
            :refine
        end
    end
  end

  # --- merge ---------------------------------------------------------------------

  defp merge(contributions, replacements, exclusions, inputs) do
    all = contributions ++ replacements

    winners =
      all
      |> Enum.group_by(& &1.rule_id)
      |> Enum.map(fn {_rule_id, group} -> Enum.min_by(group, &Layer.rank(&1.layer)) end)
      |> Enum.reject(&(&1.rule_id in exclusions))
      |> Enum.map(&refine(&1, inputs))

    rules = Enum.sort_by(Enum.map(winners, & &1.rule), & &1.id)
    combining = effective_combining(winners)
    {rules, combining, lineage(inputs, all, winners, exclusions, replacements)}
  end

  # Refinements patch the winning rule's severity and/or message in place —
  # the rule id stays stable, so findings remain filed under the same gap.
  defp refine(contribution, inputs) do
    operations =
      inputs.profile_revisions
      |> Enum.flat_map(fn revision ->
        Enum.map(revision.operations, fn operation ->
          {:ok, normalized} = AshCompliance.Oscal.ProfileOperation.normalize(operation)
          normalized
        end)
      end)
      |> Enum.filter(&(&1.op == :refine and &1.target == contribution.rule_id))

    Enum.reduce(operations, contribution, fn operation, contribution ->
      rule = %{contribution.rule | severity: operation[:severity] || contribution.rule.severity}

      rule = %{rule | message: operation[:message] || rule.message}
      %{contribution | rule: rule}
    end)
  end

  defp effective_combining([]), do: AshRules.Combining.default()

  defp effective_combining(winners) do
    winners
    |> Enum.min_by(&{Layer.rank(&1.layer), &1.rule_id})
    |> Map.get(:combining)
  end

  defp winning_contribution(contributions, rule_id) do
    contributions
    |> Enum.filter(&(&1.rule_id == rule_id))
    |> Enum.min_by(&Layer.rank(&1.layer), fn -> nil end)
  end

  defp winning_rank(contributions, rule_id) do
    case winning_contribution(contributions, rule_id) do
      nil -> nil
      contribution -> Layer.rank(contribution.layer)
    end
  end

  # --- lineage ---------------------------------------------------------------------

  defp lineage(inputs, all, winners, exclusions, replacements) do
    revision_lineage =
      Enum.map(inputs.rule_sets, fn revision ->
        included =
          Enum.count(winners, fn contribution ->
            contribution.source_id == revision.id and contribution.layer == revision.layer
          end)

        waived =
          revision.rules_json
          |> Ir.decode()
          |> case do
            {:ok, bundle} ->
              Enum.count(bundle.rules, &(&1.id in exclusions))

            {:error, _} ->
              0
          end

        effect =
          cond do
            included > 0 -> :included
            waived > 0 -> :excluded_by_waiver
            true -> :included
          end

        %{
          layer: revision.layer,
          source: revision.name,
          revision_id: revision.id,
          effect: effect,
          rule_count: included
        }
      end)

    override_lineage =
      replacements
      |> Enum.group_by(& &1.source_id)
      |> Enum.map(fn {_source_id, group} ->
        %{
          layer: hd(group).layer,
          source: hd(group).source,
          revision_id: hd(group).source_id,
          effect: :replaced,
          rule_count: length(group)
        }
      end)

    waiver_lineage =
      Enum.map(Enum.uniq(exclusions), fn rule_id ->
        contributing = Enum.find(all, &(&1.rule_id == rule_id))

        %{
          layer: :approved_override,
          source: "waiver of #{rule_id}",
          revision_id: contributing && contributing.source_id,
          effect: :excluded_by_waiver,
          rule_count: 1
        }
      end)

    revision_lineage ++ override_lineage ++ waiver_lineage
  end

  defp manifest_revision(inputs, lineage) do
    rule_set_ids = inputs.rule_sets |> Enum.map(& &1.id) |> Enum.sort()

    profile_ids =
      inputs.profile_revisions |> Enum.map(& &1.id) |> Enum.sort()

    override_ids = Enum.map(inputs.overrides, & &1.id) |> Enum.sort()

    [
      "org:#{inputs.organization_id}",
      "rs:#{Enum.join(rule_set_ids, ",")}",
      "pr:#{Enum.join(profile_ids, ",")}",
      "ov:#{Enum.join(override_ids, ",")}",
      "effects:#{Enum.map_join(lineage, "|", &"#{&1.layer}:#{&1.effect}:#{&1.rule_count}")}"
    ]
    |> Enum.join(";")
  end

  defp check_refusals([]), do: :ok

  defp check_refusals(refusals), do: {:error, Enum.reverse(refusals) |> Enum.uniq()}

  defp blank?(value), do: value in [nil, ""]
end
