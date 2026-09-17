# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Projector do
  @moduledoc """
  Macro wrapper around the `AshEvents.Projections` projector contract that
  adds the compliance translation: hydrate facts from the event, evaluate the
  active bundle through `AshRules.evaluate/3`, and translate the
  `AshRules.Result` into projection ops on the finding grain.

  Grain resolution is domain-specific, so the host declares it; the
  translation is not, so this package owns it.

      defmodule MyApp.ComplianceProjector do
        use AshCompliance.Projector,
          name: "compliance_findings_v1",
          event_log: MyApp.Events.Event,
          projection_resource: AshCompliance.Resources.Finding,
          bundle: {MyApp.Bundles, :active_bundle, []}

        grain fn event ->
          metadata = event.metadata || %{}

          %{
            organization_id: metadata["organization_id"],
            control_id: metadata["control_id"],
            subject_type: metadata["subject_type"],
            subject_id: metadata["subject_id"]
          }
        end

        project_all [:kyc_reviewed, :kyc_submitted]
      end

  The generated module satisfies the full `AshEvents.Projections.Server`
  contract (`__projector_name__`, `__grain__`, `__projection_resource__`,
  `handle_event/1,2`, `needs_current_state?/1`), so checkpointing,
  dead-letters, rebuilds and the operations toolkit work unchanged.

  Options:

    * `:name` — the projector name (blue/green: a rule change bumps it)
    * `:event_log` — the host's `AshEvents.EventLog` resource
    * `:projection_resource` — a finding resource; defaults to
      `AshCompliance.Resources.Finding`
    * `:bundle` — `{module, function, args}` resolved per event (the event
      is appended to the args), returning `{:ok, %AshRules.Ir.Bundle{}}`;
      typically reads the tenant's active `AshCompliance.Resources.PolicyBundle`
      keyed off the event's `organization_id`
    * `:facts` — fact extraction strategy, `:metadata` (default) or an MFA
      `{:module, :fun, args}` returning `{:ok, facts}`; see
      `AshCompliance.Projector.Facts`

  Handler declarations:

    * `project_all [actions]` — every listed action funnels through the
      translation, as a stateful handler (the current finding row is needed
      for breach counting and resolution transitions)
    * `project Resource, :action, fn event, finding -> ops end` — escape
      hatch: a raw handler in the underlying DSL's format, for events that
      must not be evaluated

  `AshCompliance.Projector.translate/3` and `translate/4` are the
  translation unit itself, and are safe to call (and test) directly.
  """

  @translation_actions :compliance_project_all

  @doc false
  defmacro __using__(opts) do
    quote do
      @compliance_opts unquote(opts)
      @projection_handlers []
      @compliance_project_all []
      @grain_fn nil

      import AshEvents.Projections.Projector, only: [project: 2, project: 3, grain: 1]
      import AshCompliance.Projector, only: [project_all: 1]

      @before_compile AshCompliance.Projector

      def __compliance_opts__, do: @compliance_opts
      def __projector_name__, do: Keyword.fetch!(@compliance_opts, :name)
      def __event_log__, do: Keyword.fetch!(@compliance_opts, :event_log)

      def __projection_resource__ do
        Keyword.get(@compliance_opts, :projection_resource, AshCompliance.Resources.Finding)
      end
    end
  end

  @doc """
  Declares that every listed action funnels through the compliance
  translation, as a stateful handler: the current finding row is required
  for breach counting and resolution transitions.
  """
  defmacro project_all(actions) do
    quote do
      @compliance_project_all unquote(List.wrap(actions))
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :compliance_opts)
    project_all = Module.get_attribute(env.module, @translation_actions) || []
    handlers = Module.get_attribute(env.module, :projection_handlers) |> Enum.reverse()
    grain_fn_ast = Module.get_attribute(env.module, :grain_fn)

    {stateless, stateful} = Enum.split_with(handlers, fn {_, _, _, arity} -> arity == 1 end)

    translation_clauses =
      for action <- List.wrap(project_all) do
        action = to_action_atom(action)

        quote do
          def handle_event(%{action: unquote(action)} = event, current_row) do
            AshCompliance.Projector.translate(event, current_row, __MODULE__)
          end
        end
      end

    quote do
      @doc "Returns the compliance options this projector was declared with."
      def __compliance_opts__, do: unquote(Macro.escape(opts))

      @doc "Returns the grain function (event → grain key, or nil to skip)."
      def __grain__, do: unquote(grain_fn_ast)

      @doc "Returns the raw handler descriptors {resource, action, fn_ast, arity}."
      def __handlers__, do: unquote(Macro.escape(handlers))

      unquote_splicing(Enum.map(stateless, &raw_stateless_clause/1))
      unquote_splicing(Enum.map(stateful, &raw_stateful_clause/1))
      unquote_splicing(translation_clauses)

      @doc "Fallback: events without a handler are skipped."
      def handle_event(_event), do: :skip

      @doc "Fallback: events without a handler are skipped."
      def handle_event(_event, _current_row), do: :skip

      unquote_splicing(Enum.map(stateful, &needs_state_clause/1))
      unquote_splicing(translation_needs_state_clauses(project_all))

      @doc "False unless the event is handled by a stateful handler or the translation."
      def needs_current_state?(_event), do: false
    end
  end

  defp raw_stateless_clause({nil, action, fn_ast, _}) do
    quote do
      def handle_event(%{action: unquote(action)} = event) do
        case unquote(fn_ast).(event) do
          ops when is_list(ops) and ops != [] -> {:ok, ops}
          _ -> :skip
        end
      end
    end
  end

  defp raw_stateless_clause({resource, action, fn_ast, _}) do
    quote do
      def handle_event(%{resource: unquote(resource), action: unquote(action)} = event) do
        case unquote(fn_ast).(event) do
          ops when is_list(ops) and ops != [] -> {:ok, ops}
          _ -> :skip
        end
      end
    end
  end

  defp raw_stateful_clause({nil, action, fn_ast, _}) do
    quote do
      def handle_event(%{action: unquote(action)} = event, current_row) do
        case unquote(fn_ast).(event, current_row) do
          ops when is_list(ops) and ops != [] -> {:ok, ops}
          _ -> :skip
        end
      end
    end
  end

  defp raw_stateful_clause({resource, action, fn_ast, _}) do
    quote do
      def handle_event(
            %{resource: unquote(resource), action: unquote(action)} = event,
            current_row
          ) do
        case unquote(fn_ast).(event, current_row) do
          ops when is_list(ops) and ops != [] -> {:ok, ops}
          _ -> :skip
        end
      end
    end
  end

  defp needs_state_clause({nil, action, _fn_ast, _}) do
    quote do
      def needs_current_state?(%{action: unquote(action)}), do: true
    end
  end

  defp needs_state_clause({resource, action, _fn_ast, _}) do
    quote do
      def needs_current_state?(%{resource: unquote(resource), action: unquote(action)}), do: true
    end
  end

  defp translation_needs_state_clauses(actions) do
    for action <- List.wrap(actions) do
      action = to_action_atom(action)

      quote do
        def needs_current_state?(%{action: unquote(action)}), do: true
      end
    end
  end

  defp to_action_atom(action) when is_atom(action), do: action
  defp to_action_atom(action) when is_binary(action), do: String.to_atom(action)

  @doc """
  The evaluator-to-ops translation: one event plus the current finding row
  becomes projection ops — plus one append-only `ComplianceEvaluation` row,
  written transactionally with the projection (the projector engine wraps
  both in one database transaction, so a failed projection rolls the
  evaluation back with it).

  Steps:

    1. resolve the active bundle through the projector's `:bundle` MFA
    2. extract facts from the event (`AshCompliance.Projector.Facts`)
    3. `AshRules.evaluate/3` against the bundle
    4. select the requirements filed under the finding row's control
       (`gap == control_id`) and combine them with the bundle's algorithm; a
       `:not_applicable` requirement is vacuous compliance for the row, and
       no requirement at all is `:unknown` — never silently compliant
    5. emit ops: status, severity, breach count, explanation, bundle hash,
       fired rule ids, and the timestamp transitions (`first_seen_at`,
       `last_seen_at`, `resolved_at`) taken from the *event's* timestamp, so
       a replay reproduces them exactly

  Returns `{:ok, ops}` or `:skip`.
  """
  def translate(event, current_row, projector_module) do
    opts = projector_module.__compliance_opts__()

    case resolve_bundle(opts, event) do
      {:ok, bundle} ->
        translate(event, current_row, bundle, opts)

      {:error, reason} ->
        {:ok, error_ops(event, current_row, "bundle resolution failed: #{inspect(reason)}")}
    end
  end

  @doc """
  Like `translate/3`, but with the bundle supplied — for hosts that resolve
  the bundle themselves (and for tests).
  """
  def translate(event, current_row, %AshRules.Ir.Bundle{} = bundle, opts) do
    case AshCompliance.Projector.Facts.extract(opts, event, bundle) do
      {:ok, facts} ->
        evaluate_and_translate(event, current_row, bundle, facts)

      {:error, reason} ->
        {:ok, error_ops(event, current_row, "fact extraction failed: #{inspect(reason)}")}
    end
  end

  defp evaluate_and_translate(event, current_row, bundle, facts) do
    case AshRules.evaluate(bundle, facts, seed: event[:id]) do
      {:ok, result} ->
        record_evaluation(event, current_row, bundle, result)
        {:ok, finding_ops(event, current_row, bundle, result)}

      {:error, reason} ->
        {:ok, error_ops(event, current_row, "evaluation failed: #{inspect(reason)}")}
    end
  end

  defp resolve_bundle(opts, event) do
    case Keyword.fetch!(opts, :bundle) do
      {module, function, args} -> apply(module, function, args ++ [event])
      bundle -> {:ok, bundle}
    end
  end

  defp finding_ops(event, current_row, bundle, result) do
    occurred_at = event[:occurred_at]
    control_id = current_row.control_id
    relevant = relevant_requirements(result, control_id)

    status = status_for(relevant, bundle)
    previous = current_row.status

    base = [
      {:set, :status, status},
      {:set, :last_seen_at, occurred_at},
      {:set, :bundle_hash, result.bundle_hash},
      {:set, :rule_ids, rule_ids(relevant)},
      {:set, :severity, severity(relevant)},
      {:set, :explanation, explanation(relevant)}
    ]

    base =
      if is_nil(current_row.first_seen_at) do
        [{:set, :first_seen_at, occurred_at} | base]
      else
        base
      end

    base =
      cond do
        previous == :noncompliant and status == :compliant ->
          [{:set, :resolved_at, occurred_at} | base]

        previous == :compliant and status == :noncompliant and not is_nil(current_row.resolved_at) ->
          [{:set, :resolved_at, nil} | base]

        true ->
          base
      end

    breach =
      if status == :noncompliant do
        [{:increment, :breach_count, 1}]
      else
        []
      end

    breach ++ base
  end

  # The requirements filed under this control: the ones whose gap reference
  # matches the finding row's control id.
  defp relevant_requirements(result, control_id) do
    Enum.filter(result.requirements, &(&1.gap == control_id))
  end

  # On the finding row, `:not_applicable` is vacuous compliance for the
  # control; no requirement at all is `:unknown` — never silently compliant.
  defp status_for([], _bundle), do: :unknown

  defp status_for(relevant, bundle) do
    relevant
    |> Enum.map(& &1.outcome)
    |> then(&AshRules.Combining.combine(bundle.combining, &1))
    |> case do
      :not_applicable -> :compliant
      status -> status
    end
  end

  defp severity(relevant) do
    relevant
    |> Enum.map(& &1.severity)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&severity_rank/1, fn -> nil end)
  end

  defp severity_rank(:critical), do: 0
  defp severity_rank(:high), do: 1
  defp severity_rank(:medium), do: 2
  defp severity_rank(:low), do: 3

  defp explanation([]), do: "no rules are filed under this control"

  defp explanation(relevant) do
    findings = Enum.filter(relevant, &(&1.outcome == :noncompliant))

    case findings do
      [] ->
        unknowns = Enum.filter(relevant, &(&1.outcome == :unknown))

        case unknowns do
          [] ->
            "no violation observed"

          _ ->
            "cannot evaluate: #{Enum.map_join(unknowns, ", ", &missing_summary/1)}"
        end

      findings ->
        findings
        |> Enum.map(& &1.message)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("; ")
    end
  end

  defp missing_summary(requirement) do
    missing =
      Enum.map_join(requirement.missing_facts, ", ", fn {subject, name, _value} ->
        "#{subject}/#{name}"
      end)

    "#{requirement.rule_id} (missing #{missing})"
  end

  defp rule_ids(requirements) do
    requirements
    |> Enum.map(& &1.rule_id)
    |> Enum.uniq()
  end

  defp error_ops(event, current_row, reason) do
    occurred_at = event[:occurred_at]

    ops = [
      {:set, :status, :error},
      {:set, :last_seen_at, occurred_at},
      {:set, :explanation, "evaluation failed: #{reason}"}
    ]

    if is_nil(current_row.first_seen_at) do
      [{:set, :first_seen_at, occurred_at} | ops]
    else
      ops
    end
  end

  # The evaluation is the auditor's truth: it is written transactionally with
  # the projection ops, so it can never disagree with the finding row.
  defp record_evaluation(event, current_row, bundle, result) do
    metadata = event[:metadata] || %{}

    attrs = %{
      organization_id: current_row.organization_id,
      control_id: current_row.control_id,
      subject_type: metadata["subject_type"],
      subject_id: metadata["subject_id"],
      bundle_hash: result.bundle_hash,
      bundle_revision: result.bundle_revision,
      evaluator: inspect(result.evaluator),
      compiler_version: bundle.compiler_version,
      outcome: result.overall,
      fact_snapshot_hash: AshCompliance.Projector.Facts.snapshot_hash(event),
      missing_facts: Enum.map(result.missing_facts, &format_missing/1),
      rule_ids: rule_ids(result.requirements),
      correlation_id: metadata["correlation_id"],
      source_event_id: event[:id] && to_string(event[:id]),
      evaluated_at: event[:occurred_at]
    }

    Ash.create!(AshCompliance.Resources.ComplianceEvaluation, attrs,
      action: :record,
      authorize?: false
    )
  end

  defp format_missing({subject, name, value}), do: "#{subject}/#{name} (#{inspect(value)})"
end
