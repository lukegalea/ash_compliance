# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Compiler.ContributionSource do
  @moduledoc """
  Where `AshCompliance.Compiler.compile/1` gets its contributions.

  Gathering is split from merging: a source reads whatever it reads (rows,
  files, another bounded context) and returns contributions in the shape
  `AshCompliance.Compiler.resolve/3` documents, plus the fact schema the
  verifier checks the effective rules against. The compiler then resolves
  them through the scheme it was given. A source never decides precedence.

  `AshCompliance.Compiler.DatabaseSource` is the default: today's
  `RuleSetRevision` / `ProfileRevision` / `PolicyOverride` gather.

  Callbacks:

    * `c:gather/1` — required. Receives the compile options (so a host source
      can take its own, e.g. `:job_id`). Returns `{:ok, gathered}` where
      `gathered` has `:contributions` and `:fact_schema` and may have
      `:context` (used when the caller passes none) and anything else the
      source's other callbacks need.
    * `c:revision/2` — optional. The manifest revision string stored on the
      bundle. Defaults to a digest of the scheme, context and contributing
      source ids.
    * `c:lineage/2` — optional. The lineage `compile/1` returns. Defaults to
      the resolution's per-rule lineage map.
  """

  alias AshCompliance.Compiler.Resolution

  @type gathered() :: %{
          required(:contributions) => [map()],
          required(:fact_schema) => AshRules.Ir.FactSchema.t(),
          optional(:context) => AshCompliance.Layering.context(),
          optional(atom()) => term()
        }

  @callback gather(opts :: keyword()) :: {:ok, gathered()} | {:error, String.t() | [String.t()]}

  @callback revision(gathered(), Resolution.t()) :: String.t()

  @callback lineage(gathered(), Resolution.t()) :: term()

  @optional_callbacks revision: 2, lineage: 2
end
