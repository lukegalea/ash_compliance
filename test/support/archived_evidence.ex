# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.ArchivedEvidence do
  @moduledoc """
  The test app's evidence archive: a host-side resource built with the package macro,
  on an unprefixed table the way a host keeps one it already has.
  """

  use Ash.Resource,
    domain: AshCompliance.Test.Domain,
    data_layer: AshPostgres.DataLayer

  use AshCompliance.Resources,
      {:evidence_archive, table: "evidence_artifact_archive", repo: AshCompliance.TestRepo}
end
