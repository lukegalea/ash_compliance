# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipProducerProofTest do
  @moduledoc """
  A producer that merely exists is not an evidence producer. With proof
  required, a row is wired only when the producer declares the criterion it
  records, and a test_ref that points nowhere is a problem for every class.
  """

  use ExUnit.Case, async: true

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Ownership.{Check, Resolver}

  defmodule Declares do
    @moduledoc false
    def evidence_controls, do: ["CC6.1"]
  end

  defmodule Bare do
    @moduledoc false
  end

  defmodule Broken do
    @moduledoc false
    def evidence_controls, do: :nope
  end

  defp codes(problems, id), do: for(%{criterion: ^id, code: code} <- problems, do: code)

  defp check(rows, opts),
    do: Check.check_loaded(loaded(rows), Keyword.put_new(opts, :resolver, ok_resolver()))

  defp with_producer(producer),
    do: with_row(rows(), "CC6.1", &Map.put(&1, "evidence_producer", producer))

  describe "Resolver.proves_producer/2" do
    test "a module that declares the criterion is proven" do
      assert :ok = Resolver.proves_producer("module:#{inspect(Declares)}", "CC6.1")
    end

    test "a module that exists but declares nothing is not" do
      assert {:error, _} = Resolver.proves_producer("module:#{inspect(Bare)}", "CC6.1")
    end

    test "a module declaring other criteria, or a malformed declaration, is not" do
      assert {:error, _} = Resolver.proves_producer("module:#{inspect(Declares)}", "CC6.2")
      assert {:error, _} = Resolver.proves_producer("module:#{inspect(Broken)}", "CC6.1")
    end

    test "a module that does not exist is not, and no atom is created for it" do
      assert {:error, _} = Resolver.proves_producer("module:No.Such.Producer.Zq", "CC6.1")
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir.No.Such.Producer.Zq") end
    end

    test "a file, an unknown scheme, a blank or a non-string reference is not" do
      for ref <- ["file:.github/workflows/ci.yml", "http://x", "", nil, 1] do
        assert {:error, _} = Resolver.proves_producer(ref, "CC6.1")
      end
    end
  end

  describe "Check with :require_producer_proof" do
    test "an existing but undeclared producer is a problem" do
      rows = with_producer("module:#{inspect(Bare)}")

      assert codes(check(rows, []), "CC6.1") == []
      assert codes(check(rows, require_producer_proof: true), "CC6.1") == [:unproven_producer]
    end

    test "a file producer is never proven" do
      rows = with_producer("file:.github/workflows/ci.yml")
      assert codes(check(rows, require_producer_proof: true), "CC6.1") == [:unproven_producer]
    end

    test "a declaring producer passes" do
      rows = with_producer("module:#{inspect(Declares)}")
      assert codes(check(rows, require_producer_proof: true), "CC6.1") == []
    end

    test "a producer that does not resolve is reported once, not also as unproven" do
      resolver = fn
        "module:Gone", _ -> {:error, "module Gone is not on the code path"}
        _, _ -> :ok
      end

      rows =
        with_row(
          rows(),
          "CC6.1",
          &Map.merge(&1, %{"class" => "INFRA", "evidence_producer" => "module:Gone"})
        )

      assert codes(check(rows, require_producer_proof: true, resolver: resolver), "CC6.1") ==
               [:unresolvable_producer]
    end
  end

  describe "test_ref" do
    test "a missing test file is a problem on a non-platform row too" do
      resolver = fn
        "file:test/x_test.exs", _ -> {:error, "file test/x_test.exs does not exist"}
        _, _ -> :ok
      end

      rows =
        with_row(
          rows(),
          "CC6.1",
          &Map.merge(&1, %{"class" => "HOST-APP", "operating_process" => "file:p.md"})
        )

      assert codes(check(rows, resolver: resolver), "CC6.1") == [:unresolvable_test_ref]
    end
  end
end
