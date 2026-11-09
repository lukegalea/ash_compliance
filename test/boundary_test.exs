# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.BoundaryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshCompliance.Boundary
  alias AshCompliance.Boundary.{Codegen, Info, Json, Render}
  alias AshCompliance.Test.BoundaryFixture

  @expected_dir "test/fixtures/boundary/expected"

  @env_prod "environment :production do\n class :audited\n zone \"zone-a\"\n end"
  @env_prev "environment :preview do\n class :excluded\n data_ceiling :synthetic\n end"
  @res_lb "resource :lb do\n environment :production\n kind :managed\n type \"aws_lb\"\n end"
  @res_idp "resource :idp do\n environment :production\n kind :data_source\n end"
  @res_prev "resource :prev_app do\n environment :preview\n kind :managed\n type \"fly_app\"\n end"
  @ctl_a ~s|control "CC6.6" do\n resources [:lb]\n evidence ["b", "a"]\n end|
  @ctl_b ~s|control "CC6.1" do\n resources [:idp, :lb]\n evidence ["c"]\n end|

  defp define(opts \\ []) do
    mod = "Elixir.AshCompliance.Test.Dyn#{System.unique_integer([:positive])}"
    name = Keyword.get(opts, :name, ~s("dyn"))
    dir = Keyword.get(opts, :output_dir, ~s("tmp/unused"))

    source = """
    defmodule #{mod} do
      use AshCompliance.Boundary.Declaration

      boundary do
        name #{name}
        output_dir #{dir}
      end

      environments do
        #{Enum.join(Keyword.get(opts, :environments, [@env_prod, @env_prev]), "\n")}
      end

      resources do
        #{Enum.join(Keyword.get(opts, :resources, [@res_lb, @res_idp, @res_prev]), "\n")}
      end

      controls do
        #{Enum.join(Keyword.get(opts, :controls, [@ctl_a, @ctl_b]), "\n")}
      end
    end
    """

    [{module, _}] = Code.compile_string(source)
    module
  end

  defp refused(opts, pattern) do
    error = assert_raise Spark.Error.DslError, fn -> define(opts) end
    assert Exception.message(error) =~ pattern
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "boundary_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "generated files" do
    test "equal the hand-written expected files byte for byte" do
      files = BoundaryFixture |> Info.declaration() |> Render.files()

      assert Enum.sort(Map.keys(files)) == Render.file_names()
      assert Render.file_names() == @expected_dir |> File.ls!() |> Enum.sort()

      for {name, content} <- files do
        assert content == File.read!(Path.join(@expected_dir, name)), "#{name} differs"
      end
    end

    test "do not depend on declaration order" do
      reference = define() |> Info.declaration() |> Render.files()

      permuted =
        define(
          environments: [@env_prev, @env_prod],
          resources: [@res_prev, @res_idp, @res_lb],
          controls: [@ctl_b, @ctl_a]
        )

      rotated =
        define(
          environments: [@env_prev, @env_prod],
          resources: [@res_idp, @res_prev, @res_lb],
          controls: [@ctl_b, @ctl_a]
        )

      assert permuted |> Info.declaration() |> Render.files() == reference
      assert rotated |> Info.declaration() |> Render.files() == reference
    end

    test "say owned, never compliant or evidenced" do
      for {_name, content} <- BoundaryFixture |> Info.declaration() |> Render.files() do
        refute content =~ ~r/compliant|evidenced|verified|passed/i
      end

      assert File.read!(Path.join(@expected_dir, "control-map.json")) =~ ~s("state": "owned")
    end

    test "equal text encodes to equal bytes whatever the key order" do
      a = %{b: 1, a: [%{y: true, x: nil}], c: "é\n"}
      b = %{c: "é\n", a: [%{x: nil, y: true}], b: 1}

      assert Json.encode(a) == Json.encode(b)
      assert Json.encode(%{}) == "{}\n"
      assert Json.encode(%{a: []}) == "{\n  \"a\": []\n}\n"
    end
  end

  describe "a declaration that is refused" do
    test "a control with an empty resource list" do
      refused(
        [controls: ["control \"CC1.1\" do\n resources []\n evidence [\"a\"]\n end"]],
        ~s(control "CC1.1" has no resource in an audited environment)
      )
    end

    test "a control whose only resource is in an excluded environment" do
      refused(
        [controls: ["control \"CC1.1\" do\n resources [:prev_app]\n evidence [\"a\"]\n end"]],
        ~s(control "CC1.1" has no resource in an audited environment)
      )
    end

    test "a control that references an undeclared resource" do
      refused(
        [controls: ["control \"CC1.1\" do\n resources [:ghost]\n evidence [\"a\"]\n end"]],
        ~s(control "CC1.1" references undeclared resource :ghost)
      )
    end

    test "a control that references an undeclared resource beside a declared one" do
      refused(
        [controls: ["control \"CC1.1\" do\n resources [:lb, :ghost]\n evidence [\"a\"]\n end"]],
        "references undeclared resource :ghost"
      )
    end

    test "a resource in an undeclared environment" do
      refused(
        [resources: [@res_lb, "resource :x do\n environment :nowhere\n kind :data_source\n end"]],
        "resource :x is in undeclared environment :nowhere"
      )
    end

    test "an excluded environment with no data ceiling" do
      refused(
        [environments: [@env_prod, "environment :preview do\n class :excluded\n end"]],
        "excluded environment :preview has no data ceiling"
      )
    end

    test "an audited environment that declares a data ceiling" do
      refused(
        [
          environments: [
            "environment :production do\n class :audited\n data_ceiling :synthetic\n end",
            @env_prev
          ]
        ],
        "audited environment :production declares a data ceiling"
      )
    end

    test "a data ceiling outside the allowed set" do
      assert_raise Spark.Error.DslError, fn ->
        define(
          environments: [
            @env_prod,
            "environment :preview do\n class :excluded\n data_ceiling :real\n end"
          ]
        )
      end
    end

    test "a control with no evidence, blank evidence or malformed evidence" do
      for evidence <- ["[]", "[\"\"]", "[\" \"]"] do
        refused(
          [controls: ["control \"CC1.1\" do\n resources [:lb]\n evidence #{evidence}\n end"]],
          "needs at least one non-blank evidence reference"
        )
      end

      assert_raise Spark.Error.DslError, fn ->
        define(controls: ["control \"CC1.1\" do\n resources [:lb]\n evidence [1]\n end"])
      end
    end

    test "a managed resource with no type" do
      refused(
        [resources: ["resource :lb do\n environment :production\n kind :managed\n end"]],
        "managed resource :lb has no type"
      )
    end

    test "an attribute that is not a string, boolean or integer" do
      for attributes <- ["%{\"a\" => 1.5}", "%{b: true}", "%{\"a\" => nil}", "%{\"a\" => [1]}"] do
        assert_raise Spark.Error.DslError, fn ->
          define(
            resources: [
              "resource :lb do\n environment :production\n kind :managed\n type \"t\"\n attributes #{attributes}\n end"
            ],
            controls: ["control \"CC1.1\" do\n resources [:lb]\n evidence [\"a\"]\n end"]
          )
        end
      end
    end

    test "a blank zone id" do
      refused(
        [environments: ["environment :production do\n class :audited\n zone \" \"\n end"]],
        "environment :production has a zone id that is blank"
      )
    end

    test "a blank boundary name" do
      refused([name: ~s("  ")], "the boundary needs a non-blank name")
    end

    test "duplicate environments, resources and controls" do
      refused(
        [environments: [@env_prod, @env_prod, @env_prev]],
        "environment :production is declared more than once"
      )

      refused(
        [resources: [@res_lb, @res_lb, @res_idp, @res_prev]],
        "resource :lb is declared more than once"
      )

      refused([controls: [@ctl_a, @ctl_a]], ~s(control "CC6.6" is declared more than once))
    end

    test "reports every violation at once" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          define(
            environments: ["environment :preview do\n class :excluded\n end"],
            resources: [@res_prev],
            controls: ["control \"CC1.1\" do\n resources [:ghost]\n evidence [\"a\"]\n end"]
          )
        end

      message = Exception.message(error)
      assert message =~ "no data ceiling"
      assert message =~ "undeclared resource :ghost"
    end
  end

  describe "codegen" do
    test "the fixture is current against its hand-written files" do
      assert Codegen.run(BoundaryFixture, check: true) == []
      assert :ok = Boundary.codegen(["--check", "--boundary", inspect(BoundaryFixture)])
    end

    test "a changed declaration fails --check and names the files" do
      changed =
        define(
          output_dir: inspect(@expected_dir),
          name: ~s("fixture-host"),
          environments: [@env_prod, @env_prev]
        )

      pending = Codegen.run(changed, check: true)
      assert Enum.sort(Enum.map(pending, &Path.basename/1)) == Render.file_names()

      error =
        assert_raise Ash.Error.Framework.PendingCodegen, fn ->
          Boundary.codegen(["--check", "--boundary", inspect(changed)])
        end

      assert Exception.message(error) =~ "Pending Code Generation Detected for 4 files"
    end

    test "a change to one fact leaves only the files it touches pending" do
      dir = tmp_dir()
      mod = define(output_dir: inspect(dir))
      Codegen.run(mod)
      assert Codegen.run(mod, check: true) == []

      changed =
        define(
          output_dir: inspect(dir),
          controls: [String.replace(@ctl_a, "[\"b\", \"a\"]", "[\"b\", \"a\", \"z\"]"), @ctl_b]
        )

      assert changed |> Codegen.run(check: true) |> Enum.map(&Path.basename/1) |> Enum.sort() ==
               ["boundary.snapshot.json", "control-map.json"]
    end

    test "missing, empty and malformed files are pending, never current" do
      dir = tmp_dir()
      mod = define(output_dir: inspect(dir))

      assert length(Codegen.run(mod, check: true)) == 4

      Codegen.run(mod)
      File.write!(Path.join(dir, "control-map.json"), "")
      File.write!(Path.join(dir, "infra.assertions.json"), "{not json")
      File.rm!(Path.join(dir, "boundary.auto.tfvars.json"))

      assert mod |> Codegen.run(check: true) |> Enum.map(&Path.basename/1) |> Enum.sort() ==
               ["boundary.auto.tfvars.json", "control-map.json", "infra.assertions.json"]
    end

    test "writing then checking is clean, and a dry run writes nothing" do
      dir = tmp_dir()
      mod = define(output_dir: inspect(dir))

      capture_io(fn -> Boundary.codegen(["--dry-run", "--boundary", inspect(mod)]) end)
      refute File.exists?(dir)

      capture_io(fn -> Boundary.codegen(["--boundary", inspect(mod), "--name", "ignored"]) end)
      assert Enum.sort(File.ls!(dir)) == Render.file_names()
      assert :ok = Boundary.codegen(["--check", "--dev", "--boundary", inspect(mod)])
    end

    test "--output-dir overrides the declared directory" do
      dir = tmp_dir()

      capture_io(fn ->
        Boundary.codegen(["--boundary", inspect(BoundaryFixture), "--output-dir", dir])
      end)

      assert Enum.sort(File.ls!(dir)) == Render.file_names()

      for name <- Render.file_names() do
        assert File.read!(Path.join(dir, name)) == File.read!(Path.join(@expected_dir, name))
      end
    end

    test "a module that is not a boundary is refused" do
      assert_raise Mix.Error, ~r/is not a boundary declaration/, fn ->
        Boundary.codegen(["--check", "--boundary", "Enum"])
      end
    end

    test "discovery finds the declarations compiled into the project" do
      assert BoundaryFixture in Codegen.discover()
      assert Info.declaration?(BoundaryFixture)
      refute Info.declaration?(Enum)
      refute Info.declaration?(NoSuchModule)
    end
  end
end
