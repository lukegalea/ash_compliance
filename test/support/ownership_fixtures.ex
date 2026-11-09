# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.OwnershipFixtures do
  @moduledoc false

  alias AshCompliance.Ownership.{Criteria, Evidence}

  def ok_resolver, do: fn _ref, _root -> :ok end

  def row(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class" => "PLATFORM-EVIDENCED",
        "applicability" => "applicable",
        "frequency" => "daily",
        "owner_role" => "Head of Engineering",
        "evidence_producer" => "module:Producer",
        "test_ref" => "file:test/x_test.exs"
      },
      overrides
    )
  end

  @doc "A row for every criterion in the categories, with `overrides` applied to each."
  def rows(categories \\ [:security], overrides \\ %{}) do
    for %{id: id} <- Criteria.in_categories(categories), do: row(id, overrides)
  end

  def loaded(rows), do: {:ok, %{document: %{"criteria" => rows}, rows: rows}}

  def with_row(rows, id, fun) do
    Enum.map(rows, fn
      %{"id" => ^id} = r -> fun.(r)
      r -> r
    end)
  end

  def artifact(collector, collected_at, overrides \\ %{}) do
    Map.merge(
      %{collector: collector, collected_at: collected_at, hash: Evidence.sha256("content")},
      overrides
    )
  end

  def tmp_file(name, body) do
    dir = Path.join(System.tmp_dir!(), "ash_compliance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end
end
