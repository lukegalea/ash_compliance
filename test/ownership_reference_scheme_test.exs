# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipReferenceSchemeTest do
  @moduledoc """
  A scheme the host configures (`AshCompliance.Ownership.ReferenceScheme`) answers for
  its own references, in the resolver and therefore in the check and its task. Built-in
  schemes cannot be replaced, and an unconfigured scheme stays unresolvable.
  """

  # The schemes are application env, which these tests set.
  use ExUnit.Case, async: false

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Ownership.{Check, Resolver}

  defmodule Gadget do
    @moduledoc false
    @behaviour AshCompliance.Ownership.ReferenceScheme

    # "good" exists and records CC6.1; anything else does not exist.
    @impl true
    def resolve("good", root) when is_binary(root), do: :ok
    def resolve(value, _root), do: {:error, "gadget #{value} is not declared"}

    @impl true
    def proves_producer("good", "CC6.1"), do: :ok
    def proves_producer(value, criterion), do: {:error, "gadget #{value} records no #{criterion}"}
  end

  setup do
    previous = Application.fetch_env(:ash_compliance, :reference_schemes)

    Application.put_env(:ash_compliance, :reference_schemes, %{
      "gadget" => Gadget,
      "module" => Gadget
    })

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_compliance, :reference_schemes, value)
        :error -> Application.delete_env(:ash_compliance, :reference_schemes)
      end
    end)
  end

  defp codes(problems, id), do: for(%{criterion: ^id, code: code} <- problems, do: code)

  defp check(producer, opts \\ []) do
    rows =
      with_row(rows(), "CC6.1", fn row ->
        %{row | "evidence_producer" => producer, "test_ref" => "file:mix.exs"}
      end)

    Check.check_loaded(loaded(rows), Keyword.merge([root: File.cwd!()], opts))
  end

  test "the configured scheme answers for its references" do
    assert :ok = Resolver.resolve("gadget:good", File.cwd!())
    assert {:error, "gadget gone is not declared"} = Resolver.resolve("gadget:gone", File.cwd!())
    assert :ok = Resolver.proves_producer("gadget:good", "CC6.1")

    assert {:error, "gadget good records no CC6.2"} =
             Resolver.proves_producer("gadget:good", "CC6.2")
  end

  test "a built-in scheme is never replaced, and an empty value is not a reference" do
    assert Map.keys(Resolver.schemes()) == ["gadget"]
    assert :ok = Resolver.resolve("module:AshCompliance.Ownership.Check")

    assert {:error, "module AshCompliance.Nope is not on the code path"} =
             Resolver.resolve("module:AshCompliance.Nope")

    assert {:error, message} = Resolver.resolve("gadget:", File.cwd!())
    assert message =~ "is not a module:, mix:, file: or gadget: reference"
  end

  test "an unconfigured scheme stays unresolvable and proves nothing" do
    assert {:error, message} = Resolver.resolve("widget:good", File.cwd!())
    assert message =~ "is not a module:, mix:, file: or gadget: reference"
    assert {:error, _} = Resolver.proves_producer("widget:good", "CC6.1")
  end

  test "the check uses the configured scheme for producers and test references" do
    assert codes(check("gadget:good", require_producer_proof: true), "CC6.1") == []

    assert codes(check("gadget:gone"), "CC6.1") == [:unwired_platform_row]

    rows =
      with_row(rows(), "CC6.2", fn row ->
        %{row | "evidence_producer" => "gadget:good", "test_ref" => "gadget:gone"}
      end)

    problems = Check.check_loaded(loaded(rows), root: File.cwd!(), require_producer_proof: true)

    assert [
             %{code: :unwired_platform_row, message: "test_ref: gadget gone is not declared"},
             %{
               code: :unproven_producer,
               message: "evidence producer: gadget good records no CC6.2"
             }
           ] = Enum.filter(problems, &(&1.criterion == "CC6.2")) |> Enum.sort_by(& &1.code, :desc)
  end

  test "without configuration nothing beyond the built-in schemes resolves" do
    Application.delete_env(:ash_compliance, :reference_schemes)

    assert Resolver.schemes() == %{}
    assert {:error, message} = Resolver.resolve("gadget:good", File.cwd!())
    assert message =~ "is not a module:, mix: or file: reference"
  end
end
