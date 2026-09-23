# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Status do
  @moduledoc """
  Record-level compliance status: "is this appointment compliant?" as a query.

  The guard path vetoes a transition when the active bundle fires; this module
  answers the same question *read-only*, for surfaces that display the state
  rather than gate a write — a badge on the appointment row, a "why" tooltip,
  a checklist before the operator commits. It runs the exact machinery the
  guard path exercises: the organization's active `PolicyBundle`, decoded and
  evaluated against the record's facts through `AshRules`, with no writes of
  any kind (no audit row — surfacing status is not a decision to audit).

  Entry point: `AshCompliance.status_for/2`. The result:

      {:ok, %AshCompliance.Status{
        status: :noncompliant,
        rules: [
          %AshCompliance.Status.Verdict{
            rule_id: "appt.checkin_requires_weight",
            severity: :high,
            gap: "record the patient's weight before check-in",
            status: :noncompliant
          },
          ...
        ],
        bundle_hash: "...", bundle_revision: "...",
        missing_facts: [...], facts: [...]
      }}

  Per-rule verdicts use the outcome lattice's vocabulary — `compliant`,
  `noncompliant`, `not_applicable` (plus `unknown` and `error`, which never
  collapse to compliant) — and each carries the rule id, severity and gap text
  the guard quotes on refusals. `AshCompliance.Status.message/1` renders that
  refusal vocabulary directly for hosts that want one string.
  """

  defstruct [:status, :rules, :bundle_hash, :bundle_revision, :missing_facts, :facts]

  alias AshCompliance.Resources.PolicyBundle
  alias AshCompliance.Status.Verdict

  # Options status_for/1 consumes itself; everything else reaches the fact
  # builder as context (the guard's `transition_to` is the canonical case).
  @reserved_opts [:organization, :bundle, :facts, :fact_builder]

  @type overall() :: AshRules.Outcome.t()

  @type t() :: %__MODULE__{
          status: overall(),
          rules: [Verdict.t()],
          bundle_hash: String.t(),
          bundle_revision: String.t(),
          missing_facts: [AshRules.Facts.triple()],
          facts: [AshRules.Facts.triple()]
        }

  @doc """
  Evaluates the organization's active bundle against a record.

  Options:

    * `:organization` — required. The organization id, an MFA
      (`{MyApp.Compliance, :organization_id, []}` — the way the guard and the
      projector resolve it), or a zero-arity capture.
    * `:fact_builder` — the host's `AshCompliance.FactBuilder` (module,
      `{module, function}`, or capture). Defaults to the record's own module
      implementing the behaviour; see the behaviour for the contract.
    * `:facts` — explicit fact triples, bypassing the builder. For callers
      that already hold working memory.
    * `:bundle` — a pre-fetched `AshCompliance.Resources.PolicyBundle` or a
      pre-decoded `AshRules.Ir.Bundle`, bypassing the active-bundle read.

  Returns `{:ok, status}`, or `{:error, :no_active_bundle}` when the
  organization has no active bundle (absence is meaningful: a host may render
  "no rules in force" rather than pretend compliance), `{:error,
  :no_fact_builder}` when neither an explicit nor a default builder can be
  resolved, and `{:error, term}` when the bundle cannot be read/decoded or the
  facts fail the bundle's fact schema — the same fail-closed posture the guard
  takes, reported instead of refused.
  """
  @spec for(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def for(record, opts) do
    builder_opts = Keyword.drop(opts, @reserved_opts)

    with {:ok, bundle} <- fetch_bundle(opts),
         {:ok, facts} <- build_facts(record, opts, builder_opts),
         {:ok, result} <- AshRules.evaluate(bundle, facts) do
      {:ok, new(result, facts)}
    end
  end

  @doc """
  The fired rules' gap texts, quoted in the guard's refusal vocabulary:
  `"compliance: gap (rule_id)"` entries joined with `"; "`. `nil` when no rule
  fired — nothing to refuse, nothing for a surface to quote.
  """
  @spec message(t()) :: String.t() | nil
  def message(%__MODULE__{rules: rules}) do
    fired = Enum.reject(rules, &(&1.status in [:compliant, :not_applicable]))

    case fired do
      [] ->
        nil

      fired ->
        "compliance: " <> Enum.map_join(fired, "; ", &"#{&1.gap} (#{&1.rule_id})")
    end
  end

  # --- assembly -----------------------------------------------------------------

  defp new(result, facts) do
    %__MODULE__{
      status: result.overall,
      rules: Enum.map(result.requirements, &Verdict.new/1),
      bundle_hash: result.bundle_hash,
      bundle_revision: result.bundle_revision,
      missing_facts: result.missing_facts,
      facts: facts
    }
  end

  # --- the bundle -----------------------------------------------------------------

  # Trusted machinery, exactly like the guard's and the projector's bundle
  # reads: fetching the active bundle is a headless system read with no user
  # request attached, so it runs under `authorize?: false` on purpose.
  defp fetch_bundle(opts) do
    case opts[:bundle] do
      %AshRules.Ir.Bundle{} = bundle ->
        {:ok, bundle}

      %PolicyBundle{} = bundle ->
        decode_bundle(bundle)

      nil ->
        active_bundle(organization(opts))

      other ->
        {:error, {:invalid_bundle, other}}
    end
  end

  defp organization(opts) do
    case opts[:organization] do
      nil ->
        raise ArgumentError,
              "AshCompliance.status_for/2 requires the :organization option — " <>
                "the organization id, an MFA like {MyApp.Compliance, :organization_id, []}, " <>
                "or a zero-arity capture"

      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        apply(module, function, args)

      fun when is_function(fun, 0) ->
        fun.()

      value ->
        value
    end
  end

  defp active_bundle(organization) do
    case AshCompliance.Domain.active_policy_bundle(organization, authorize?: false) do
      # Absence is meaningful, and part of the contract: no active bundle
      # reads as a distinct error, not as "compliant" or a crash.
      {:ok, nil} ->
        {:error, :no_active_bundle}

      {:ok, bundle} ->
        decode_bundle(bundle)

      {:error, reason} ->
        {:error, {:bundle_read_failed, reason}}
    end
  end

  defp decode_bundle(bundle), do: AshRules.Ir.decode(bundle.rules_json)

  # --- the facts --------------------------------------------------------------------

  defp build_facts(record, opts, builder_opts) do
    cond do
      facts = opts[:facts] ->
        {:ok, facts}

      builder = opts[:fact_builder] ->
        apply_builder(builder, record, builder_opts)

      module = record_module(record) ->
        if implements_fact_builder?(module) do
          {:ok, module.facts(record, builder_opts)}
        else
          {:error, :no_fact_builder}
        end

      true ->
        {:error, :no_fact_builder}
    end
  end

  defp record_module(record) when is_map(record) do
    case record do
      %{__struct__: module} when is_atom(module) -> module
      _other -> nil
    end
  end

  defp record_module(_record), do: nil

  defp apply_builder(builder, record, opts) when is_atom(builder) do
    if implements_fact_builder?(builder) do
      {:ok, builder.facts(record, opts)}
    else
      {:error, {:not_a_fact_builder, builder}}
    end
  end

  defp apply_builder({module, function}, record, opts)
       when is_atom(module) and is_atom(function) do
    {:ok, apply(module, function, [record, opts])}
  end

  defp apply_builder(capture, record, _opts) when is_function(capture, 1),
    do: {:ok, capture.(record)}

  defp apply_builder(capture, record, opts) when is_function(capture, 2),
    do: {:ok, capture.(record, opts)}

  defp apply_builder(other, _record, _opts), do: {:error, {:not_a_fact_builder, other}}

  defp implements_fact_builder?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :facts, 2)
  end
end
