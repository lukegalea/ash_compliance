# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Compiler.DatabaseSource do
  @moduledoc """
  The default `AshCompliance.Compiler.ContributionSource`: active
  `RuleSetRevision` rows (as `:add` at their layer), in-force
  `PolicyOverride` rows (`:waive` / `:replace` at `:approved_override`), and
  the tenant policy set's `ProfileRevision` operations (`:exclude`,
  `:refine`, `:parameterize` at `:profile_refinement`; `include` and
  `supplement` are documentary and contribute nothing).

  Every contribution is unscoped: this source compiles organization-wide
  bundles. Its lineage and manifest revision are the revision-level forms the
  `PolicyBundle` has always stored.

  Options: `:organization_id` (required) and `:now` (the compile clock,
  defaulting to now truncated to seconds).
  """

  @behaviour AshCompliance.Compiler.ContributionSource

  alias AshCompliance.Domain
  alias AshRules.Ir

  @override_layer :approved_override
  @profile_layer :profile_refinement

  @impl true
  def gather(opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    now = Keyword.get(opts, :now) || DateTime.utc_now() |> DateTime.truncate(:second)

    inputs = %{
      organization_id: organization_id,
      now: now,
      rule_sets: active_rule_sets(organization_id, now),
      profile_revisions: profile_revisions(organization_id),
      overrides: valid_overrides(organization_id, now)
    }

    with {:ok, adds, schema} <- decode_sources(inputs) do
      {:ok,
       %{
         contributions:
           adds ++ override_contributions(inputs.overrides) ++ profile_contributions(inputs),
         fact_schema: schema,
         context: %{},
         inputs: inputs
       }}
    end
  end

  # --- gathering ---------------------------------------------------------------

  # Trusted machinery: the compile is a headless system operation (the
  # PolicyBundle compile action, a host console, a worker) — no user request
  # is attached, so these reads run under `authorize?: false` on purpose.
  # Host-facing entry points thread `actor:`/`authorize?:` instead (see
  # `AshCompliance.Oscal` and `AshCompliance.Testing`).
  defp active_rule_sets(organization_id, now) do
    # The compile clock IS the as-of (§1): the same pinned `now` that drives
    # waiver expiry drives the revision reads, so one instant governs the
    # whole gather and the compile stays deterministic — "in force at now"
    # is the temporal containment read, not a wall-clock glance. Plain reads
    # are as-of-now, so an unpinned compile behaves exactly as before the
    # swap.
    Domain.active_rule_set_revisions!(organization_id, as_of: now, authorize?: false)
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
    decoded =
      Enum.map(inputs.rule_sets, fn revision ->
        case Ir.decode(revision.rules_json) do
          {:ok, bundle} -> {:ok, {revision, bundle}}
          {:error, errors} -> {:error, revision.name, errors}
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
        Enum.flat_map(decoded, fn {:ok, {revision, bundle}} ->
          Enum.map(bundle.rules, fn rule ->
            %{
              op: :add,
              rule_id: rule.id,
              rule: rule,
              layer: revision.layer,
              combining: revision.combining,
              source_id: revision.id,
              source: revision.name
            }
          end)
        end)

      bundles = Enum.map(decoded, fn {:ok, {_, bundle}} -> bundle end)

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

  # Overrides are approval artifacts at the override layer. A `:waive` is an
  # exclusion; anything else is a replacement whose rule set is decoded here
  # (a decode failure is carried, and refused only if the replacement passes
  # its permission checks first — the order the compiler always checked in).
  defp override_contributions(overrides) do
    Enum.map(overrides, fn override ->
      base = %{
        rule_id: override.rule_id,
        layer: @override_layer,
        combining: :deny_overrides,
        source_id: override.id,
        source: "override:#{override.id}"
      }

      case override.kind do
        :waive -> Map.put(base, :op, :waive)
        _replace -> Map.merge(base, %{op: :replace, rules: replacement_rules(override)})
      end
    end)
  end

  defp replacement_rules(%{replacement_rules_json: json}) when json in [nil, ""], do: nil

  defp replacement_rules(%{replacement_rules_json: json}) do
    case Ir.decode(json) do
      {:ok, bundle} -> bundle.rules
      {:error, errors} -> {:error, List.wrap(errors)}
    end
  end

  defp profile_contributions(inputs) do
    Enum.flat_map(inputs.profile_revisions, fn revision ->
      revision.operations
      # Operations round-trip through JSONB storage (string keys/values);
      # normalize back to the atom-keyed form before use.
      |> Enum.map(fn operation ->
        {:ok, normalized} = AshCompliance.Oscal.ProfileOperation.normalize(operation)
        normalized
      end)
      |> Enum.reject(&(&1.op in [:include, :supplement]))
      |> Enum.map(fn operation ->
        %{
          op: operation.op,
          rule_id: operation.target,
          layer: @profile_layer,
          severity: operation[:severity],
          message: operation[:message],
          params: operation[:params] || %{},
          source_id: revision.id,
          source: "profile:#{revision.id}"
        }
      end)
    end)
  end

  # --- lineage and manifest ------------------------------------------------------

  @impl true
  def lineage(%{inputs: inputs}, resolution) do
    exclusions =
      resolution.excluded |> Enum.map(& &1.rule_id) |> Enum.reverse() |> Enum.uniq()

    winners = resolution.winners
    all = resolution.declarations ++ resolution.replacements

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
      resolution.replacements
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
      Enum.map(exclusions, fn rule_id ->
        contributing = Enum.find(all, &(&1.rule_id == rule_id))

        %{
          layer: @override_layer,
          source: "waiver of #{rule_id}",
          revision_id: contributing && contributing.source_id,
          effect: :excluded_by_waiver,
          rule_count: 1
        }
      end)

    revision_lineage ++ override_lineage ++ waiver_lineage
  end

  @impl true
  def revision(%{inputs: inputs} = gathered, resolution) do
    lineage = lineage(gathered, resolution)
    rule_set_ids = inputs.rule_sets |> Enum.map(& &1.id) |> Enum.sort()
    profile_ids = inputs.profile_revisions |> Enum.map(& &1.id) |> Enum.sort()
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
end
