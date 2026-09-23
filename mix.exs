# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lukegalea/ash_compliance"

  @description """
  The compliance control plane and data plane on Ash: OSCAL-flavored catalogs,
  profiles and waivers compiled into immutable AshRules bundles, with findings
  projected from an event log and append-only evaluations as the auditor
  truth.
  """

  def project do
    [
      app: :ash_compliance,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      docs: &docs/0,
      description: @description,
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ecto_sql],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    application(Mix.env())
  end

  defp application(:test) do
    [
      mod: {AshCompliance.TestApp, []},
      extra_applications: [:logger]
    ]
  end

  defp application(_) do
    [extra_applications: [:logger]]
  end

  defp package do
    [
      name: :ash_compliance,
      licenses: ["MIT"],
      maintainers: ["Luke Galea <luke@ideaforge.org>"],
      files: ~w(lib documentation CHANGELOG.md LICENSE README.md usage-rules.md
        mix.exs .formatter.exs),
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp deps do
    [
      # The rule engine seam: bundles in, results out.
      {:ash_rules, github: "lukegalea/ash_rules"},
      # Control plane storage. Resources resolve their repo through
      # application env (:ash_compliance, :repo), so hosts wire their own.
      {:ash, "~> 3.5"},
      {:ash_postgres, "~> 2.0"},
      {:spark, "~> 2.0", runtime: false},
      # The event log and the projector engine the ComplianceProjector runs on.
      {:ash_events, "~> 0.7.0"},
      {:ash_events_projections, github: "lukegalea/ash_events_projections"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      # Canonical JSON for content hashes.
      {:jason, "~> 1.2"},
      # The ruleset editor LiveView. A hard dependency rather than optional,
      # the same way ash_decisions declares its editor: the editor is half of
      # what this package is for, and an optional dependency that the shipped
      # module needs anyway buys a compile-time failure instead of a
      # resolvable one.
      {:phoenix_live_view, "~> 1.0"},
      # Dev / test
      {:oban, "~> 2.18", only: [:dev, :test]},
      {:stream_data, "~> 1.1"},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      # LiveView tests need an HTML query engine. `lazy_html` rather than
      # floki because it is what phoenix_live_view 1.x selects against; the
      # same declaration ash_decisions makes for the same reason.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/how-it-works.md",
        "documentation/topics/layering-and-combining.md",
        "documentation/topics/the-projector.md",
        "documentation/topics/oscal.md",
        "documentation/topics/what-it-refuses.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Topics: ~r'documentation/topics'
      ],
      groups_for_modules: [
        "Control plane": [
          ~r/AshCompliance\.Resources/,
          AshCompliance.Compiler
        ],
        "Data plane": [
          AshCompliance.Projector,
          AshCompliance.Resources.Finding,
          AshCompliance.Resources.ComplianceEvaluation,
          AshCompliance.Resources.EvidenceArtifact
        ],
        "Status queries": [
          AshCompliance.Status,
          AshCompliance.FactBuilder
        ],
        Interop: [AshCompliance.Oscal, AshCompliance.Workers.NotifyProjectors],
        Internals: ~r/.*/
      ]
    ]
  end

  defp aliases do
    [
      credo: "credo --strict",
      # The database must exist (and be migrated, oban_jobs included) before
      # the test application boots Oban.
      "test.create": "ecto.create --quiet",
      "test.migrate": "ecto.migrate --migrations-path priv/test_repo/migrations",
      test: ["test.create", "test.migrate", "test"]
    ]
  end
end
