# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipCheckTest do
  use ExUnit.Case, async: true

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Ownership.{Check, ControlFile, Resolver}

  defp check(rows, opts \\ []) do
    Check.check_loaded(loaded(rows), Keyword.put_new(opts, :resolver, ok_resolver()))
  end

  defp codes(problems, id), do: for(%{criterion: ^id, code: code} <- problems, do: code)

  test "a complete file has no problems" do
    assert check(rows()) == []
  end

  test "a missing criterion is named" do
    problems = check(Enum.reject(rows(), &(&1["id"] == "CC7.4")))
    assert codes(problems, "CC7.4") == [:missing_criterion]
  end

  test "no owner role" do
    problems = check(with_row(rows(), "CC6.1", &Map.put(&1, "owner_role", "  ")))
    assert codes(problems, "CC6.1") == [:no_owner_role]
  end

  test "an unresolvable producer on a non-platform row" do
    resolver = fn
      "module:Bad", _ -> {:error, "module Bad is not on the code path"}
      _, _ -> :ok
    end

    rows =
      with_row(
        rows(),
        "CC6.1",
        &Map.merge(&1, %{"class" => "INFRA", "evidence_producer" => "module:Bad"})
      )

    assert codes(check(rows, resolver: resolver), "CC6.1") == [:unresolvable_producer]
  end

  test "an unresolvable operating process" do
    resolver = fn
      "file:gone.md", _ -> {:error, "file gone.md does not exist"}
      _, _ -> :ok
    end

    rows = with_row(rows(), "CC6.2", &Map.put(&1, "operating_process", "file:gone.md"))
    assert codes(check(rows, resolver: resolver), "CC6.2") == [:unresolvable_process]
  end

  test "a producer-requiring class with no producer" do
    rows = with_row(rows(), "CC6.1", &Map.delete(&1, "evidence_producer"))
    assert codes(check(rows), "CC6.1") == [:no_evidence_producer]
  end

  test "no test_ref" do
    rows = with_row(rows(), "CC8.1", &Map.delete(&1, "test_ref"))
    assert codes(check(rows), "CC8.1") == [:no_test_ref]
  end

  test "an unwired PLATFORM row: test or producer that does not resolve" do
    resolver = fn
      "file:test/x_test.exs", _ -> {:error, "file test/x_test.exs does not exist"}
      _, _ -> :ok
    end

    assert codes(check(rows(), resolver: resolver), "CC6.1") == [:unwired_platform_row]

    producer_resolver = fn
      "module:Producer", _ -> {:error, "module Producer is not on the code path"}
      _, _ -> :ok
    end

    assert codes(check(rows(), resolver: producer_resolver), "CC6.1") == [:unwired_platform_row]
  end

  test "a recurring ORG row with no process" do
    rows = with_row(rows(), "CC1.4", &Map.merge(&1, %{"class" => "ORG", "frequency" => "annual"}))
    assert codes(check(rows), "CC1.4") == [:no_process]
  end

  test "a recurring HOST-APP row with no process" do
    rows =
      with_row(
        rows(),
        "CC6.3",
        &Map.merge(&1, %{"class" => "HOST-APP", "frequency" => "quarterly"})
      )

    assert codes(check(rows), "CC6.3") == [:no_process]
  end

  test "a continuous ORG row does not need a process, a recurring one with a process is clean" do
    continuous =
      with_row(rows(), "CC1.4", &Map.merge(&1, %{"class" => "ORG", "frequency" => "continuous"}))

    assert codes(check(continuous), "CC1.4") == []

    with_process =
      with_row(
        rows(),
        "CC1.4",
        &Map.merge(&1, %{
          "class" => "ORG",
          "frequency" => "annual",
          "operating_process" => "file:p.md"
        })
      )

    assert codes(check(with_process), "CC1.4") == []
  end

  test "a VENDOR row with no complementary controls mapped" do
    vendor = %{"class" => "VENDOR", "vendor_ref" => "Hosting provider report"}

    none = with_row(rows(), "CC9.2", &Map.merge(&1, vendor))
    assert :no_complementary_controls in codes(check(none), "CC9.2")

    empty =
      with_row(rows(), "CC9.2", &Map.merge(&1, Map.put(vendor, "complementary_controls", [])))

    assert :no_complementary_controls in codes(check(empty), "CC9.2")

    dangling =
      with_row(
        rows(),
        "CC9.2",
        &Map.merge(&1, Map.put(vendor, "complementary_controls", ["CC99.9"]))
      )

    assert :no_complementary_controls in codes(check(dangling), "CC9.2")

    mapped =
      with_row(
        rows(),
        "CC9.2",
        &Map.merge(&1, Map.put(vendor, "complementary_controls", ["CC6.1"]))
      )

    assert codes(check(mapped), "CC9.2") == []
  end

  test "a VENDOR row with no vendor_ref" do
    rows =
      with_row(
        rows(),
        "CC9.2",
        &Map.merge(&1, %{"class" => "VENDOR", "complementary_controls" => ["CC6.1"]})
      )

    assert codes(check(rows), "CC9.2") == [:no_vendor_ref]
  end

  test "a stored status is an error, in scope or not" do
    rows = with_row(rows(), "CC6.1", &Map.put(&1, "status", "passing"))
    assert :status_stored in codes(check(rows), "CC6.1")

    out_of_scope = rows([:security]) ++ [row("P1.1", %{"status" => "ok"})]
    assert :status_stored in codes(check(out_of_scope), "P1.1")
  end

  test "invalid class, applicability and frequency" do
    rows =
      rows()
      |> with_row("CC1.1", &Map.put(&1, "class", "MAGIC"))
      |> with_row("CC1.2", &Map.put(&1, "frequency", "sometimes"))
      |> with_row("CC1.3", &Map.put(&1, "applicability", "maybe"))

    problems = check(rows)
    assert codes(problems, "CC1.1") == [:invalid_class]
    assert codes(problems, "CC1.2") == [:invalid_frequency]
    assert codes(problems, "CC1.3") == [:invalid_applicability]
  end

  test "not_applicable needs a rationale" do
    rows = with_row(rows(), "CC6.4", &Map.put(&1, "applicability", "not_applicable"))
    assert codes(check(rows), "CC6.4") == [:no_rationale]

    ok =
      with_row(
        rows(),
        "CC6.4",
        &Map.merge(&1, %{"applicability" => "not_applicable", "rationale" => "No premises."})
      )

    assert codes(check(ok), "CC6.4") == []
  end

  test "unknown keys, duplicate rows, unknown criteria and malformed rows" do
    rows =
      rows()
      |> with_row("CC1.1", &Map.put(&1, "stauts", "x"))
      |> Kernel.++([row("CC1.2"), row("CC99.1"), "not a row", %{"class" => "ORG"}])

    problems = check(rows)
    assert codes(problems, "CC1.1") == [:unknown_key]
    assert :duplicate_row in codes(problems, "CC1.2")
    assert codes(problems, "CC99.1") == [:unknown_criterion]
    assert Enum.count(problems, &(&1.code == :malformed_row)) == 2
  end

  test "categories scope the audit" do
    assert [] = check(rows(), categories: [:security])
    problems = check(rows(), categories: [:security, :availability])
    assert Enum.count(problems, &(&1.code == :missing_criterion)) == 3
  end

  describe "the file" do
    test "missing" do
      assert [%{code: :control_file, message: message}] = Check.run("/nonexistent/controls.json")
      assert message =~ "does not exist"
    end

    test "malformed JSON" do
      path = tmp_file("controls.json", "{not json")
      assert [%{code: :control_file, message: message}] = Check.run(path)
      assert message =~ "not valid JSON"
    end

    test "not an object, and criteria that is not a list" do
      assert [%{code: :control_file}] = Check.run(tmp_file("a.json", "[]"))
      assert [%{code: :control_file}] = Check.run(tmp_file("b.json", ~s({"criteria": {}})))
    end

    test "an existing file without a criteria key stays valid and reports every criterion missing" do
      path =
        tmp_file(
          "controls.json",
          ~s({"$comment": ["x"], "frameworks": [{"id": "soc2"}], "controls": [{"id": "CC6.1", "questions": ["q1"]}]})
        )

      assert {:ok, %{rows: []}} = ControlFile.load(path)
      assert Enum.count(Check.run(path), &(&1.code == :missing_criterion)) == 33
    end
  end

  describe "the resolver" do
    test "modules, tasks and files" do
      assert :ok = Resolver.resolve("module:AshCompliance.Ownership.Check")
      assert :ok = Resolver.resolve("module:Elixir.AshCompliance.Ownership.Check")
      assert {:error, _} = Resolver.resolve("module:AshCompliance.Nope")
      assert :ok = Resolver.resolve("mix:ash_compliance.controls.check")
      assert {:error, _} = Resolver.resolve("mix:ash_compliance.nope")
      assert :ok = Resolver.resolve("file:mix.exs", File.cwd!())
      assert {:error, _} = Resolver.resolve("file:nope.md", File.cwd!())
    end

    test "anything else, blank or non-string is unresolvable" do
      assert {:error, _} = Resolver.resolve("manual:someone")
      assert {:error, _} = Resolver.resolve("")
      assert {:error, _} = Resolver.resolve(nil)
    end
  end
end
