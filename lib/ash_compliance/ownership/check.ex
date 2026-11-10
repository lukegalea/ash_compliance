# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Check do
  @moduledoc """
  Checks a control file against the criteria catalogue.

  Returns a list of problems, each naming the criterion it concerns. An empty
  list means every in-scope criterion has an owned, wired row. It does not
  mean any control is operating: that is decided from evidence by
  `AshCompliance.Ownership.Freshness`.

  Problems raised, by `code`:

    * `:control_file` - the file is missing or not valid
    * `:missing_criterion` - an in-scope criterion has no row
    * `:duplicate_row` / `:unknown_criterion` - the row set disagrees with the catalogue
    * `:malformed_row` / `:unknown_key` - a row is not an object, or has a key outside the schema
    * `:status_stored` - a row carries `status`
    * `:invalid_class` / `:invalid_applicability` / `:invalid_frequency`
    * `:no_owner_role`
    * `:no_rationale` - a `not_applicable` row without a reason
    * `:no_evidence_producer` / `:unresolvable_producer`
    * `:no_process` / `:unresolvable_process` - recurring `ORG` and `HOST-APP` rows need one
    * `:no_test_ref` / `:unresolvable_test_ref` - every applicable row names a test that exists
    * `:unproven_producer` - with `:require_producer_proof`, a producer that does not declare
      the criterion it records evidence for
    * `:unwired_platform_row` - a `PLATFORM-*` row whose test or producer does not resolve
    * `:no_vendor_ref` / `:no_complementary_controls` - `VENDOR` rows

  Options:

    * `:categories` - categories in the audit (default `[:security]`)
    * `:root` - directory `file:` references resolve against (default cwd)
    * `:resolver` - `(ref, root -> :ok | {:error, String.t()})`
    * `:require_producer_proof` - when `true`, a producer that merely exists is
      not enough: it must declare the criterion it records evidence for
      (see `AshCompliance.Ownership.Resolver.proves_producer/2`). Default
      `false`
    * `:prover` - `(ref, criterion_id -> :ok | {:error, String.t()})`, used with
      `:require_producer_proof`
  """

  alias AshCompliance.Ownership.{ControlFile, Criteria, Frequency, Resolver}

  @type problem :: %{criterion: String.t() | nil, code: atom(), message: String.t()}

  @producer_classes ~w(PLATFORM-EVIDENCED HOST-APP INFRA)

  @doc "Loads `path` and checks it."
  @spec run(Path.t(), keyword()) :: [problem()]
  def run(path, opts \\ []) do
    check_loaded(ControlFile.load(path), opts)
  end

  @doc "Checks the result of `AshCompliance.Ownership.ControlFile.load/1`."
  @spec check_loaded({:ok, map()} | {:error, term()}, keyword()) :: [problem()]
  def check_loaded({:error, error}, _opts),
    do: [problem(nil, :control_file, ControlFile.describe_error(error))]

  def check_loaded({:ok, %{rows: rows}}, opts) do
    categories = Keyword.get(opts, :categories, [:security])
    root = Keyword.get(opts, :root, File.cwd!())
    resolver = Keyword.get(opts, :resolver, &Resolver.resolve/2)

    prover =
      if Keyword.get(opts, :require_producer_proof, false),
        do: Keyword.get(opts, :prover, &Resolver.proves_producer/2)

    ctx = %{root: root, resolver: resolver, prover: prover, ids: row_ids(rows)}

    in_scope = Criteria.in_categories(categories)
    by_id = rows |> Enum.filter(&is_map/1) |> Enum.group_by(&Map.get(&1, "id"))

    missing =
      for %{id: id} <- in_scope, not Map.has_key?(by_id, id) do
        problem(id, :missing_criterion, "no row for this criterion")
      end

    structural =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(&row_structure/1)

    duplicates =
      for {id, [_, _ | _]} <- by_id, is_binary(id) do
        problem(id, :duplicate_row, "more than one row for this criterion")
      end

    per_row =
      for %{id: id} <- in_scope, row <- Map.get(by_id, id, []), do: check_row(id, row, ctx)

    missing ++ structural ++ duplicates ++ List.flatten(per_row)
  end

  defp row_ids(rows) do
    for %{"id" => id} <- Enum.filter(rows, &is_map/1), is_binary(id), into: MapSet.new(), do: id
  end

  defp row_structure({row, index}) when not is_map(row),
    do: [problem(nil, :malformed_row, "row #{index} is not an object")]

  defp row_structure({%{"id" => id} = row, _index}) when is_binary(id) do
    unknown =
      if Criteria.known?(id),
        do: [],
        else: [problem(id, :unknown_criterion, "#{id} is not in the criteria catalogue")]

    unknown ++ status_problems(id, row)
  end

  defp row_structure({_row, index}),
    do: [problem(nil, :malformed_row, "row #{index} has no string id")]

  defp check_row(id, row, ctx) do
    class = Map.get(row, "class")

    key_problems(id, row) ++
      common_problems(id, row, class) ++
      class_problems(id, row, class, ctx)
  end

  defp key_problems(id, row) do
    for key <- Map.keys(row), key not in ControlFile.row_keys(), key != "status" do
      problem(id, :unknown_key, "unknown key #{inspect(key)}")
    end
  end

  defp status_problems(id, row) do
    if Map.has_key?(row, "status"),
      do: [
        problem(id, :status_stored, "status is derived from evidence and must never be stored")
      ],
      else: []
  end

  defp common_problems(id, row, class) do
    applicability = Map.get(row, "applicability")
    frequency = Map.get(row, "frequency")

    List.flatten([
      if(class in ControlFile.classes(),
        do: [],
        else:
          problem(
            id,
            :invalid_class,
            "class #{inspect(class)} is not one of #{Enum.join(ControlFile.classes(), ", ")}"
          )
      ),
      if(applicability in ControlFile.applicability_values(),
        do: [],
        else:
          problem(
            id,
            :invalid_applicability,
            "applicability must be applicable or not_applicable"
          )
      ),
      if(blank?(Map.get(row, "owner_role")),
        do: problem(id, :no_owner_role, "no owner role"),
        else: []
      ),
      if(applicability == "not_applicable" and blank?(Map.get(row, "rationale")),
        do: problem(id, :no_rationale, "not_applicable needs a rationale"),
        else: []
      ),
      if(applicability == "applicable" and not Frequency.valid?(frequency),
        do:
          problem(
            id,
            :invalid_frequency,
            "frequency #{inspect(frequency)} is not one of #{Enum.join(Frequency.names(), ", ")}"
          ),
        else: []
      )
    ])
  end

  defp class_problems(id, row, class, ctx) do
    if Map.get(row, "applicability") == "applicable" and class in ControlFile.classes() do
      applicable_problems(id, row, class, ctx)
    else
      []
    end
  end

  defp applicable_problems(id, row, class, ctx) do
    producer = Map.get(row, "evidence_producer")
    process = Map.get(row, "operating_process")
    test_ref = Map.get(row, "test_ref")
    platform? = String.starts_with?(class, "PLATFORM-")

    List.flatten([
      producer_problems(id, class, producer, ctx, platform?),
      process_problems(id, row, class, process, ctx),
      test_problems(id, test_ref, ctx, platform?),
      vendor_problems(id, row, class, ctx)
    ])
  end

  defp producer_problems(id, class, producer, ctx, platform?) do
    cond do
      blank?(producer) and class in @producer_classes ->
        problem(id, :no_evidence_producer, "#{class} needs an evidence producer")

      blank?(producer) ->
        []

      true ->
        case ctx.resolver.(producer, ctx.root) do
          :ok ->
            proof_problems(id, producer, ctx)

          {:error, why} when platform? ->
            problem(id, :unwired_platform_row, "evidence producer: #{why}")

          {:error, why} ->
            problem(id, :unresolvable_producer, "evidence producer: #{why}")
        end
    end
  end

  defp proof_problems(_id, _producer, %{prover: nil}), do: []

  defp proof_problems(id, producer, %{prover: prover}) do
    case prover.(producer, id) do
      :ok -> []
      {:error, why} -> problem(id, :unproven_producer, "evidence producer: #{why}")
    end
  end

  defp process_problems(id, row, class, process, ctx) do
    recurring_owner? =
      class in ["ORG", "HOST-APP"] and Frequency.recurring?(Map.get(row, "frequency"))

    cond do
      blank?(process) and recurring_owner? ->
        problem(id, :no_process, "a recurring #{class} row needs an operating process")

      blank?(process) ->
        []

      true ->
        case ctx.resolver.(process, ctx.root) do
          :ok -> []
          {:error, why} -> problem(id, :unresolvable_process, "operating process: #{why}")
        end
    end
  end

  defp test_problems(id, test_ref, ctx, platform?) do
    cond do
      blank?(test_ref) ->
        problem(id, :no_test_ref, "no test_ref")

      platform? ->
        case ctx.resolver.(test_ref, ctx.root) do
          :ok -> []
          {:error, why} -> problem(id, :unwired_platform_row, "test_ref: #{why}")
        end

      true ->
        case ctx.resolver.(test_ref, ctx.root) do
          :ok -> []
          {:error, why} -> problem(id, :unresolvable_test_ref, "test_ref: #{why}")
        end
    end
  end

  defp vendor_problems(id, row, "VENDOR", ctx) do
    mapped = Map.get(row, "complementary_controls")

    mapped_problems =
      if is_list(mapped) and mapped != [] do
        for ref <- mapped, not (is_binary(ref) and MapSet.member?(ctx.ids, ref)) do
          problem(
            id,
            :no_complementary_controls,
            "complementary control #{inspect(ref)} has no row in this file"
          )
        end
      else
        [
          problem(
            id,
            :no_complementary_controls,
            "a VENDOR row must map the complementary controls we operate"
          )
        ]
      end

    ref_problem =
      if blank?(Map.get(row, "vendor_ref")),
        do: [problem(id, :no_vendor_ref, "a VENDOR row needs a vendor_ref")],
        else: []

    ref_problem ++ mapped_problems
  end

  defp vendor_problems(_id, _row, _class, _ctx), do: []

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

  defp problem(criterion, code, message),
    do: %{criterion: criterion, code: code, message: message}
end
