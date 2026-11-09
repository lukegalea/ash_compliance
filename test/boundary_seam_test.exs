# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.BoundarySeamTest do
  @moduledoc """
  The production facts do not know about the controls, and the controls read
  the production facts. These tests hold that line.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshCompliance.Boundary
  alias AshCompliance.Boundary.{Codegen, GeneratedFiles, Info, Render}
  alias AshCompliance.Boundary.Controls.Render, as: ControlsRender

  @production_names Render.file_names()
  @control_names ControlsRender.file_names()

  @prod "environment :production do\n class :production\n end"
  @other "environment :other do\n class :production\n end"
  @prev "environment :preview do\n class :non_production\n data_ceiling :synthetic\n end"
  @lb "resource :lb do\n environment :production\n kind :managed\n type \"lb\"\n end"
  @db "resource :db do\n environment :production\n kind :managed\n type \"db\"\n end"
  @ctl ~s|control "CC1.1" do\n resources [:lb]\n evidence ["a"]\n end|

  defp define(opts \\ []) do
    mod = "Elixir.AshCompliance.Test.Seam#{System.unique_integer([:positive])}"
    use_line = Keyword.get(opts, :use, "use AshCompliance.Boundary.Declaration")

    controls =
      case Keyword.get(opts, :controls_block, :default) do
        :none -> ""
        :default -> "controls do\n audited_environments [:production]\n #{@ctl}\n end"
        block -> block
      end

    source = """
    defmodule #{mod} do
      #{use_line}

      boundary do
        name "seam"
        output_dir #{inspect(Keyword.get(opts, :output_dir, "tmp/unused"))}
      end

      environments do
        #{Enum.join(Keyword.get(opts, :environments, [@prod, @prev]), "\n")}
      end

      resources do
        #{Enum.join(Keyword.get(opts, :resources, [@lb]), "\n")}
      end

      #{controls}
    end
    """

    [{module, _}] = Code.compile_string(source)
    module
  end

  defp production_alone(opts \\ []) do
    define(
      Keyword.merge([use: "use AshCompliance.Boundary.Production", controls_block: :none], opts)
    )
  end

  defp refused(opts, pattern) do
    error = assert_raise Spark.Error.DslError, fn -> define(opts) end
    assert Exception.message(error) =~ pattern
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "seam_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "a declaration with the production extension alone" do
    test "compiles, validates and emits only the three production files" do
      mod = production_alone()

      assert Spark.extensions(mod) == [Boundary]
      assert Info.declaration?(mod)
      assert mod |> GeneratedFiles.files() |> Map.keys() |> Enum.sort() == @production_names

      assert @production_names ==
               ~w(boundary.auto.tfvars.json boundary.snapshot.json infra.assertions.json)
    end

    test "joins the controls extension through Spark's extensions option" do
      mod =
        define(
          use:
            "use AshCompliance.Boundary.Production, extensions: [AshCompliance.Boundary.Controls]"
        )

      assert mod |> GeneratedFiles.files() |> Map.keys() |> Enum.sort() ==
               Enum.sort(@production_names ++ @control_names)
    end

    test "writes and checks clean with no control file on disk" do
      dir = tmp_dir()
      mod = production_alone(output_dir: dir)

      capture_io(fn -> Boundary.codegen(["--boundary", inspect(mod)]) end)
      assert Enum.sort(File.ls!(dir)) == @production_names
      assert :ok = Boundary.codegen(["--check", "--boundary", inspect(mod)])
    end

    test "has no controls section to write into" do
      capture_io(:stderr, fn ->
        assert_raise CompileError, fn ->
          production_alone(
            controls_block: "controls do\n audited_environments [:production]\n end"
          )
        end
      end)
    end

    test "the production rules still refuse" do
      assert_raise Spark.Error.DslError, ~r/has no data ceiling/, fn ->
        production_alone(
          environments: [@prod, "environment :preview do\n class :non_production\n end"]
        )
      end
    end
  end

  describe "the two sides are independent" do
    test "changing only the controls leaves every production file byte-identical" do
      base = define()

      changed =
        define(
          controls_block:
            ~s|controls do\n audited_environments [:production]\n control "CC9.9" do\n resources [:lb]\n evidence ["z", "y"]\n end\n end|
        )

      a = GeneratedFiles.files(base)
      b = GeneratedFiles.files(changed)

      for name <- @production_names, do: assert(a[name] == b[name], "#{name} changed")
      for name <- @control_names, do: refute(a[name] == b[name], "#{name} did not change")
    end

    test "changing the audited environments alone leaves the production files untouched" do
      base = define(environments: [@prod, @other, @prev])

      changed =
        define(
          environments: [@prod, @other, @prev],
          controls_block:
            "controls do\n audited_environments [:production, :other]\n #{@ctl}\n end"
        )

      a = GeneratedFiles.files(base)
      b = GeneratedFiles.files(changed)
      for name <- @production_names, do: assert(a[name] == b[name])
      refute a["controls.snapshot.json"] == b["controls.snapshot.json"]
    end

    test "changing only a resource changes the production files" do
      base = GeneratedFiles.files(define())

      changed =
        GeneratedFiles.files(define(resources: [@lb, @db]))

      for name <- @production_names, do: refute(base[name] == changed[name], "#{name} unchanged")
    end

    test "--check fails on a change to either side" do
      dir = tmp_dir()
      capture_io(fn -> Boundary.codegen(["--boundary", inspect(define(output_dir: dir))]) end)

      resource_changed = define(output_dir: dir, resources: [@lb, @db])

      controls_changed =
        define(
          output_dir: dir,
          controls_block:
            ~s|controls do\n audited_environments [:production]\n control "CC1.1" do\n resources [:lb]\n evidence ["a", "b"]\n end\n end|
        )

      assert resource_changed
             |> Codegen.run(check: true)
             |> Enum.map(&Path.basename/1)
             |> Enum.sort() ==
               @production_names

      for mod <- [resource_changed, controls_changed] do
        assert_raise Ash.Error.Framework.PendingCodegen, fn ->
          Boundary.codegen(["--check", "--boundary", inspect(mod)])
        end
      end

      assert controls_changed
             |> Codegen.run(check: true)
             |> Enum.map(&Path.basename/1)
             |> Enum.sort() ==
               @control_names
    end
  end

  describe "the production side names no audit concept" do
    defp forbidden do
      [
        {"Controls", ~r/\bControls\b/},
        {"audit", ~r/audit/i},
        {"criterion", ~r/criteri(on|a)/i},
        {"evidence", ~r/evidence/i},
        {"compliance", ~r/compliance/i},
        {"controls as a section", ~r/\bcontrols\b/i},
        {"a control module", ~r/\.Controls?\b/},
        {"a control entity",
         ~r/\bcontrol\s+("|do\b|map\b|entity\b|section\b|option\b|link\b)|:control\b/}
      ]
    end

    # The namespace of this library is the only place the word may appear.
    defp violations(source) do
      stripped = String.replace(source, "AshCompliance", "")
      for {label, regex} <- forbidden(), Regex.match?(regex, stripped), do: label
    end

    defp production_files do
      ["lib/ash_compliance/boundary.ex" | Path.wildcard("lib/ash_compliance/boundary/**/*.ex")]
      |> Enum.reject(&String.starts_with?(&1, "lib/ash_compliance/boundary/controls"))
      |> Enum.sort()
    end

    test "the scan covers the production files and not the controls" do
      files = production_files()
      assert "lib/ash_compliance/boundary.ex" in files
      assert "lib/ash_compliance/boundary/render.ex" in files
      assert "lib/ash_compliance/boundary/rules.ex" in files
      assert "lib/ash_compliance/boundary/codegen.ex" in files
      assert "lib/ash_compliance/boundary/transformers/enforce_rules.ex" in files
      refute Enum.any?(files, &String.contains?(&1, "controls"))
    end

    test "no production file names a control or an audit concept" do
      for file <- production_files() do
        assert violations(File.read!(file)) == [], "#{file} names a forbidden word"
      end
    end

    test "the scan fails when a forbidden word is added to a real file" do
      source = File.read!("lib/ash_compliance/boundary/rules.ex")
      assert violations(source) == []

      for word <-
            ~w(Controls audited audit criterion criteria evidence compliance controls) ++
              [
                ~s(control "CC1" do),
                "AshCompliance.Boundary.Controls.Rules",
                "control map",
                ":control"
              ] do
        assert violations(source <> "\n# #{word}\n") != [], "#{word} slipped through"
      end
    end

    test "the scan allows unrelated uses of the word control" do
      for phrase <- [
            "version control",
            "flow control",
            "the host controlled it",
            "uncontrolled growth",
            "AshCompliance.Boundary"
          ] do
        assert violations("# #{phrase}\n") == [], "#{phrase} was rejected"
      end
    end
  end

  describe "controls refuse" do
    test ":non_production without a ceiling" do
      refused(
        [environments: [@prod, "environment :preview do\n class :non_production\n end"]],
        "non-production environment :preview has no data ceiling"
      )
    end

    test ":production with a ceiling" do
      refused(
        [
          environments: [
            "environment :production do\n class :production\n data_ceiling :synthetic\n end"
          ]
        ],
        "production environment :production declares a data ceiling"
      )
    end

    test "a control present with audited_environments missing" do
      refused(
        [controls_block: "controls do\n #{@ctl}\n end"],
        "audited_environments is missing"
      )
    end

    test "an empty audited_environments" do
      refused(
        [controls_block: "controls do\n audited_environments []\n #{@ctl}\n end"],
        "audited_environments is empty"
      )
    end

    test "an audited name that is undeclared" do
      refused(
        [
          controls_block:
            "controls do\n audited_environments [:production, :nowhere]\n #{@ctl}\n end"
        ],
        "audited environment :nowhere is not declared"
      )
    end

    test "an audited name that is :non_production" do
      refused(
        [
          controls_block:
            "controls do\n audited_environments [:production, :preview]\n #{@ctl}\n end"
        ],
        "audited environment :preview is not a production environment"
      )
    end

    test "a control whose only resource is outside the audited environments" do
      other_lb = "resource :other_lb do\n environment :other\n kind :managed\n type \"lb\"\n end"

      refused(
        [
          environments: [@prod, @other, @prev],
          resources: [@lb, other_lb],
          controls_block:
            ~s|controls do\n audited_environments [:production]\n control "CC1.1" do\n resources [:other_lb]\n evidence ["a"]\n end\n end|
        ],
        ~s(control "CC1.1" has no resource in an audited environment)
      )
    end

    test "a removed class value" do
      for class <- [":audited", ":excluded"] do
        assert_raise Spark.Error.DslError, fn ->
          define(environments: ["environment :production do\n class #{class}\n end"])
        end
      end
    end
  end
end
