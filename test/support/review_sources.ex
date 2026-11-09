# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.ReviewSources do
  @moduledoc false
  # Access review sources with fixed answers.

  defmodule App do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "app"

    @impl true
    def entries(_context) do
      {:ok,
       [
         %{person_key: "alice@example.test", grants: [%{ref: "role:admin"}]},
         %{person_key: "Bob@Example.test ", grants: [%{ref: "role:viewer", scope: "tenant-1"}]}
       ]}
    end
  end

  defmodule Legacy do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "legacy"

    @impl true
    def entries(_context) do
      {:ok,
       [
         %{person_key: "bob@example.test", grants: [%{"ref" => "rbac:pm"}]},
         %{person_key: "carol@example.test", grants: [%{ref: "rbac:leader"}]}
       ]}
    end
  end

  defmodule Errored do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "errored"

    @impl true
    def entries(_context), do: {:error, :connection_refused}
  end

  defmodule Empty do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "empty"

    @impl true
    def entries(_context), do: {:ok, []}
  end

  defmodule Raising do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "raising"

    @impl true
    def entries(_context), do: raise("boom")
  end

  defmodule Exiting do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "exiting"

    @impl true
    def entries(_context), do: exit(:gone)
  end

  defmodule Slow do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "slow"

    @impl true
    def entries(_context) do
      Process.sleep(:infinity)
    end
  end

  defmodule Malformed do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "malformed"

    @impl true
    def entries(_context), do: {:ok, [%{person_key: "", grants: [%{ref: "x"}]}]}
  end

  defmodule NoGrants do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "nogrants"

    @impl true
    def entries(_context), do: {:ok, [%{person_key: "dave@example.test", grants: []}]}
  end

  defmodule NotAList do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "notalist"

    @impl true
    def entries(_context), do: {:ok, %{person_key: "x"}}
  end

  defmodule BadReturn do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "badreturn"

    @impl true
    def entries(_context), do: :ok
  end

  defmodule SameIdAsApp do
    @moduledoc false
    @behaviour AshCompliance.AccessReview.Source

    @impl true
    def id, do: "app"

    @impl true
    def entries(_context), do: {:ok, [%{person_key: "z@example.test", grants: [%{ref: "r"}]}]}
  end
end
