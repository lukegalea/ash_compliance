# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Compiler do
  @moduledoc """
  Resolves layered contributions into the effective `AshRules.Ir.Bundle`,
  through a declared layering scheme.

  The work is split in two:

    * **gather** — an `AshCompliance.Compiler.ContributionSource` reads
      contributions. The default, `AshCompliance.Compiler.DatabaseSource`,
      reads `RuleSetRevision`, `ProfileRevision` and `PolicyOverride` rows.
    * **merge** — `resolve/3`, a pure function of contributions, scheme and
      context, applies the scheme's permissions and precedence and returns an
      `AshCompliance.Compiler.Resolution`: effective rules, per-rule lineage
      and refusals.

  `compile/1` is the two together plus verification. With no `:scheme` and
  no `:source` it is exactly the compile this package has always done: the
  six-rank `AshCompliance.Layering.Default` over the database gather, the
  same bundle, the same hash, the same lineage, the same refusals.

  The scheme is code (a module implementing `AshCompliance.Layering`), passed
  explicitly — never an application-env switch and never a runtime list —
  so the order a bundle was compiled under is always the order a reviewer
  read. Overreach is refused loudly, whichever scheme: an edit beyond its
  layer's reach, against a protected layer, or a "tighten" that is not
  strictly stronger never silently applies.

  Waivers are bounded-time artifacts evaluated against the compile clock:
  expired waivers are excluded from the gather entirely, so a waiver lapsing
  returns its rule to the effective bundle without any action being taken.
  """

  alias AshCompliance.Compiler.DatabaseSource
  alias AshCompliance.Compiler.Resolution
  alias AshCompliance.Compiler.Resolver
  alias AshCompliance.Layering

  alias AshRules.Ir.Bundle
  alias AshRules.Verifier

  @typedoc """
  One contribution to a resolution. Only `:layer` and either `:rule` (for
  `:add`) or `:rule_id` (for edits) are required; everything else defaults.

    * `:op` — `:add` (default), `:tighten`, `:exclude`, `:refine`, `:waive`,
      `:replace` or `:parameterize`.
    * `:layer` — a layer the scheme declares.
    * `:rule_id` — the rule declared (defaults to `rule.id`) or targeted.
    * `:rule` — the `AshRules.Ir.Rule` an `:add` declares.
    * `:rules` — a `:replace`'s replacement rules: a list, `nil` (blank), or
      `{:error, messages}` (did not decode).
    * `:params` — an `:add`'s initial params, or a `:tighten`/`:parameterize`'s
      new values, e.g. `%{min_amount: 2_000_000}`.
    * `:strength` — an `:add`'s param directions, e.g.
      `%{min_amount: :at_least}` (see `AshCompliance.Layering.default_stronger?/3`).
    * `:scope` — where it applies, e.g. `%{property_group: id}`; `nil`/`%{}`
      applies everywhere.
    * `:severity`, `:message` — a `:refine`'s patch.
    * `:combining` — the rule set's algorithm (default `:deny_overrides`).
    * `:source_id`, `:source` — provenance, carried into lineage and refusals.
  """
  @type contribution() :: %{
          optional(:op) => Layering.op(),
          required(:layer) => Layering.layer(),
          optional(:rule_id) => String.t(),
          optional(:rule) => AshRules.Ir.Rule.t(),
          optional(:rules) => [AshRules.Ir.Rule.t()] | {:error, [String.t()]} | nil,
          optional(:params) => map(),
          optional(:strength) => %{optional(atom()) => Layering.direction()},
          optional(:scope) => Layering.scope(),
          optional(:severity) => AshRules.Ir.Rule.severity() | nil,
          optional(:message) => String.t() | nil,
          optional(:combining) => AshRules.Combining.algorithm(),
          optional(:source_id) => term(),
          optional(:source) => term()
        }

  @typedoc "What the default compile did — stored on the PolicyBundle as data."
  @type lineage_entry :: %{
          required(:layer) => Layering.layer(),
          required(:source) => String.t(),
          required(:revision_id) => String.t() | nil,
          required(:effect) => :included | :excluded_by_waiver | :replaced,
          required(:rule_count) => non_neg_integer()
        }

  @doc """
  Resolves `contributions` under `scheme` for `context`. Pure: no reads, no
  clock. "What does this job need?" is
  `resolve(contributions, MyScheme, %{pmc: p, property_group: [g], job: j})`.

  Contributions whose scope does not match the context are dropped (not
  refused), so a job-level exclusion never narrows a PMC-level read.
  """
  @spec resolve([contribution()], module(), Layering.context()) :: Resolution.t()
  def resolve(contributions, scheme \\ Layering.Default, context \\ %{}),
    do: Resolver.resolve(contributions, scheme, context)

  @doc """
  Compiles the effective bundle.

  Options:

    * `:scheme` — the `AshCompliance.Layering` module (default
      `AshCompliance.Layering.Default`).
    * `:source` — the `AshCompliance.Compiler.ContributionSource` module
      (default `AshCompliance.Compiler.DatabaseSource`).
    * `:context` — the resolution context (default: the source's, else `%{}`).
    * every other option reaches the source's `gather/1`; the default source
      takes `:organization_id` (required) and `:now` (the compile clock,
      defaulting to now truncated to seconds — waiver expiry and the
      revision as-of read are evaluated against it, and tests pin it).

  Returns `{:ok, bundle, lineage}` or `{:error, errors}`. The lineage is the
  source's (`c:AshCompliance.Compiler.ContributionSource.lineage/2`), else the
  resolution's per-rule lineage map.
  """
  @spec compile(keyword()) ::
          {:ok, Bundle.t(), [lineage_entry()] | map()} | {:error, String.t() | [String.t()]}
  def compile(opts) do
    scheme = Keyword.get(opts, :scheme, Layering.Default)
    source = Keyword.get(opts, :source, DatabaseSource)

    with {:ok, gathered} <- source.gather(opts),
         context = Keyword.get(opts, :context) || Map.get(gathered, :context) || %{},
         {:ok, resolution} <- resolved(gathered.contributions, scheme, context) do
      case Verifier.verify(gathered.fact_schema, resolution.rules) do
        :ok ->
          revision = revision(source, gathered, resolution)

          bundle =
            Bundle.new(resolution.rules, gathered.fact_schema,
              revision: revision,
              fact_schema_revision: revision,
              combining: resolution.combining
            )

          {:ok, bundle, lineage(source, gathered, resolution)}

        {:error, errors} ->
          {:error, errors}
      end
    end
  end

  defp resolved(contributions, scheme, context) do
    resolution = resolve(contributions, scheme, context)

    if Resolution.ok?(resolution),
      do: {:ok, resolution},
      else: {:error, Resolution.messages(resolution)}
  end

  defp revision(source, gathered, resolution) do
    Code.ensure_loaded(source)

    if function_exported?(source, :revision, 2) do
      source.revision(gathered, resolution)
    else
      default_revision(resolution)
    end
  end

  defp lineage(source, gathered, resolution) do
    Code.ensure_loaded(source)

    if function_exported?(source, :lineage, 2),
      do: source.lineage(gathered, resolution),
      else: resolution.lineage
  end

  # Scheme, context and every contributing source id — enough that two
  # bundles from different inputs never share a revision string.
  defp default_revision(resolution) do
    sources =
      (resolution.declarations ++
         resolution.replacements ++
         resolution.excluded ++ Enum.concat(Map.values(resolution.lineage)))
      |> Enum.map(&inspect(&1.source_id))
      |> Enum.uniq()
      |> Enum.sort()

    context =
      resolution.context
      |> Enum.sort()
      |> Enum.map_join(",", fn {k, v} -> "#{k}=#{inspect(v)}" end)

    digest =
      :crypto.hash(:sha256, Enum.join(sources, ","))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "scheme:#{inspect(resolution.scheme)};ctx:#{context};src:#{digest}"
  end
end
