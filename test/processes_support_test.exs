# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.ProcessesSupportTest do
  @moduledoc """
  The pieces under the process machinery: canonical JSON, the source merge, the
  overdue worker's arguments and the decision catalogue.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.AccessReview.Merge
  alias AshCompliance.Processes.{Canonical, Decisions, Templates}
  alias AshCompliance.Workers.ProcessOverdue

  describe "canonical json" do
    test "does not depend on key order" do
      a = %{"b" => 1, "a" => %{"y" => [1, 2], "x" => nil}}
      b = %{"a" => %{"x" => nil, "y" => [1, 2]}, "b" => 1}
      assert Canonical.encode!(a) == Canonical.encode!(b)
      assert Canonical.sha256(a) == Canonical.sha256(b)
    end

    test "renders atoms and datetimes as text and distinguishes values" do
      assert Canonical.encode!(%{k: :v, at: ~U[2026-01-01 00:00:00.000000Z]}) ==
               ~s({"at":"2026-01-01T00:00:00.000000Z","k":"v"})

      refute Canonical.sha256(%{"a" => 1}) == Canonical.sha256(%{"a" => 2})
    end

    test "refuses what JSON cannot hold" do
      assert_raise ArgumentError, fn -> Canonical.encode!(%{"p" => self()}) end
      assert_raise ArgumentError, fn -> Canonical.encode!(%{"s" => %URI{}}) end
    end
  end

  describe "merge" do
    test "normalises person keys" do
      assert Merge.normalise_key("  A@B.test ") == {:ok, "a@b.test"}

      for bad <- [nil, "", "  ", 1, :a, %{}] do
        assert Merge.normalise_key(bad) == :error
      end
    end

    test "a grant without a ref, or that is not a map, is malformed" do
      for grants <- [
            [%{}],
            [%{ref: ""}],
            [%{ref: 5}],
            [:admin],
            ["admin"],
            [%{ref: "x", at: self()}]
          ] do
        source = fn -> {:ok, [%{person_key: "a@b.test", grants: grants}]} end
        assert %{status: :malformed} = run(source)
      end
    end

    test "grants in different orders digest the same" do
      one = [%{person_key: "a@b.test", grants: [%{ref: "x"}, %{ref: "y"}]}]
      two = [%{person_key: "a@b.test", grants: [%{ref: "y"}, %{ref: "x"}]}]
      assert [%{entitlement_digest: d}] = Merge.merge([{"s", run(fn -> {:ok, one} end).entries}])
      assert [%{entitlement_digest: ^d}] = Merge.merge([{"s", run(fn -> {:ok, two} end).entries}])
    end

    defp run(fun) do
      Merge.run_source(__MODULE__.Dynamic, %{fun: fun})
    end

    defmodule Dynamic do
      @moduledoc false
      def entries(%{fun: fun}), do: fun.()
    end
  end

  describe "the overdue worker" do
    defmodule Source do
      @moduledoc false
      def open_tasks(_org, _opts), do: {:ok, []}
    end

    test "cancels instead of guessing at its arguments" do
      org = Ecto.UUID.generate()
      name = inspect(Source)

      assert :ok =
               ProcessOverdue.perform(%Oban.Job{
                 args: %{"organization_id" => org, "task_source" => name}
               })

      for args <- [
            %{"task_source" => name},
            %{"organization_id" => "nope", "task_source" => name},
            %{"organization_id" => org},
            %{"organization_id" => org, "task_source" => "Elixir.NoSuchSourceModuleAnywhere"},
            %{"organization_id" => org, "task_source" => "String"},
            %{"organization_id" => org, "task_source" => 5}
          ] do
        assert {:cancel, _} = ProcessOverdue.perform(%Oban.Job{args: args})
      end
    end
  end

  describe "the decision catalogue" do
    test "knows exactly the decisions the templates cite" do
      assert Decisions.keys() == Enum.sort(Templates.decisions())
      refute Decisions.exists?("compliance.other")
      refute Decisions.exists?(nil)
    end

    test "hashes are stable and documents are not empty" do
      for key <- Decisions.keys() do
        assert Decisions.content_hash(key) == Decisions.content_hash(key)
        assert Decisions.xml(key) =~ "<decision "
      end
    end
  end
end
