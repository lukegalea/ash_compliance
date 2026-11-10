# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshCompliance.Controls.Check do
  @moduledoc """
  Checks a control file's ownership rows against the criteria catalogue.

      mix ash_compliance.controls.check
      mix ash_compliance.controls.check --file docs/controls.json --categories security,availability
      mix ash_compliance.controls.check --require-producer-proof
      mix ash_compliance.controls.check --report

  Fails, naming each row, when an in-scope criterion has no row, no owner
  role, an unresolvable evidence producer or operating process, no `test_ref`,
  an unwired `PLATFORM-*` row, a recurring `ORG` or `HOST-APP` row with no
  process, or a `VENDOR` row with no complementary controls mapped. A `status`
  key on any row is an error. See `AshCompliance.Ownership.Check` for every
  problem code.

  Options:

    * `--file` - the control file (default `docs/controls.json`)
    * `--categories` - comma-separated categories in the audit: `security`,
      `availability`, `processing_integrity`, `confidentiality`, `privacy`
      (default `security`)
    * `--root` - directory `file:` references resolve against (default cwd)
    * `--require-producer-proof` - a producer that merely exists is not enough:
      its module must export `evidence_controls/0` listing the criterion it
      records evidence for. Without it, an unwired producer passes this check
      (the sweep still reads the row `:unknown`). Off by default so a host can
      adopt the check first; turn it on once its producers declare their
      criteria, and keep it on in CI.
    * `--report` - list every problem and exit 0, so a host can adopt the
      check before the file is finished. Without it, any problem exits non-zero.

  The exit status in `--report` mode says nothing about the file. Read the
  listing.
  """

  use Mix.Task

  alias AshCompliance.Ownership.{Check, Criteria}

  @shortdoc "Checks the control file against the SOC 2 criteria catalogue"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          file: :string,
          categories: :string,
          root: :string,
          report: :boolean,
          require_producer_proof: :boolean
        ]
      )

    file = Keyword.get(opts, :file, "docs/controls.json")
    categories = parse_categories(Keyword.get(opts, :categories, "security"))
    root = Keyword.get(opts, :root, File.cwd!())

    problems =
      Check.run(Path.expand(file, root),
        categories: categories,
        root: root,
        require_producer_proof: Keyword.get(opts, :require_producer_proof, false)
      )

    in_scope = length(Criteria.in_categories(categories))

    report(problems, file, in_scope)

    if problems != [] and not Keyword.get(opts, :report, false) do
      Mix.raise("#{length(problems)} problem(s) in #{file}")
    end
  end

  defp report([], file, in_scope),
    do:
      Mix.shell().info(
        "#{file}: no problems across #{in_scope} criteria (this says nothing about evidence)"
      )

  defp report(problems, file, in_scope) do
    Mix.shell().info("#{file}: #{length(problems)} problem(s) across #{in_scope} criteria")

    for %{criterion: criterion, code: code, message: message} <- problems do
      Mix.shell().info("  #{criterion || "-"}  [#{code}]  #{message}")
    end
  end

  defp parse_categories(text) do
    known = Map.new(Criteria.categories(), &{Atom.to_string(&1), &1})

    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn name ->
      Map.get(known, name) ||
        Mix.raise("unknown category #{inspect(name)}; use #{Enum.join(Map.keys(known), ", ")}")
    end)
    |> case do
      [] -> Mix.raise("--categories needs at least one category")
      categories -> categories
    end
  end
end
