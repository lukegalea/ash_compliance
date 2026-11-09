# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipCriteriaTest do
  use ExUnit.Case, async: true

  alias AshCompliance.Ownership.Criteria

  test "the catalogue holds all 61 criteria with unique ids" do
    assert length(Criteria.all()) == 61
    assert length(Enum.uniq(Criteria.ids())) == 61
  end

  test "category sizes match the 2017 criteria" do
    counts = Criteria.all() |> Enum.frequencies_by(& &1.category)

    assert counts == %{
             security: 33,
             availability: 3,
             processing_integrity: 5,
             confidentiality: 2,
             privacy: 18
           }
  end

  test "every criterion has a non-empty title and an id shaped for its category" do
    shapes = %{
      security: ~r/\ACC[1-9]\.\d\z/,
      availability: ~r/\AA1\.\d\z/,
      processing_integrity: ~r/\API1\.\d\z/,
      confidentiality: ~r/\AC1\.\d\z/,
      privacy: ~r/\AP[1-8]\.\d\z/
    }

    for %{id: id, title: title, category: category} <- Criteria.all() do
      assert String.trim(title) != ""
      assert id =~ Map.fetch!(shapes, category)
    end
  end

  test "get/1 and known?/1 reject anything outside the catalogue" do
    assert %{id: "CC6.1"} = Criteria.get("CC6.1")
    refute Criteria.known?("CC6.9")
    refute Criteria.known?(nil)
    assert Criteria.get(:cc61) == nil
  end
end
