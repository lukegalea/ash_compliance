# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance do
  @moduledoc """
  The compliance control plane and data plane on Ash.

  `ash_compliance` sits on top of `ash_rules` and turns rule bundles into an
  operating compliance program:

    * a **control plane** — catalogs, controls, profiles, waivers, tenant
      policy sets, and rule-set revisions with a lifecycle
      (draft → validated → approved → active → retired/revoked), compiled by
      `AshCompliance.Compiler` through the fixed layering precedence into
      immutable, content-hashed `AshRules.Ir.Bundle` snapshots
      (`AshCompliance.Resources.PolicyBundle`);
    * a **data plane** — findings projected from the event log through
      `AshEvents.Projections` (finding grain `[organization_id, control_id,
      subject_type, subject_id]`), append-only `ComplianceEvaluation` records
      as the auditor truth, and immutable `EvidenceArtifact` references;
    * **OSCAL interop** — catalog and profile import/export through
      `AshCompliance.Oscal` and the `mix ash_compliance.import_oscal` /
      `mix ash_compliance.export_oscal` tasks.

  There is deliberately **no API layer**: resources, actions, the compiler and
  the projector only. Wire exposure is the host's concern.

  ## Host wiring

  Every resource resolves its Ecto repo through application env:

      config :ash_compliance, repo: MyApp.Repo

  Include `AshCompliance.Domain` in your Ash domains and add the projector
  engine's supervisor alongside your own:

      config :ash_compliance, projectors: [MyApp.ComplianceProjector]

  See the README for the full wiring walkthrough.
  """

  @doc """
  The repo the control-plane resources use. Resolved lazily so hosts only need
  to set `config :ash_compliance, repo: MyApp.Repo`.
  """
  @spec repo() :: module()
  def repo do
    Application.get_env(:ash_compliance, :repo) ||
      raise """
      AshCompliance requires a repo. Configure it in config/config.exs:

          config :ash_compliance, repo: MyApp.Repo
      """
  end

  @doc "The configured projector modules (the drain worker nudges these)."
  @spec projectors() :: [module()]
  def projectors do
    Application.get_env(:ash_compliance, :projectors, [])
  end
end
