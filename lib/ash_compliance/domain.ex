# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Domain do
  @moduledoc """
  The Ash domain containing every `ash_compliance` resource.

  Hosts include this domain in their Ash configuration:

      config :ash, ash_domains: [..., AshCompliance.Domain]

  There is deliberately no API layer on this domain: resources, actions, the
  compiler and the projector only. Wire exposure (JSON:API, GraphQL, LiveView)
  is the host's concern.
  """

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource(AshCompliance.Resources.Catalog)
    resource(AshCompliance.Resources.CatalogVersion)
    resource(AshCompliance.Resources.Control)
    resource(AshCompliance.Resources.ControlRevision)
    resource(AshCompliance.Resources.Profile)
    resource(AshCompliance.Resources.ProfileRevision)
    resource(AshCompliance.Resources.RuleSetRevision)
    resource(AshCompliance.Resources.PolicyBundle)
    resource(AshCompliance.Resources.TenantPolicySet)
    resource(AshCompliance.Resources.PolicyOverride)
    resource(AshCompliance.Resources.ControlMapping)
    resource(AshCompliance.Resources.Finding)
    resource(AshCompliance.Resources.ComplianceEvaluation)
    resource(AshCompliance.Resources.EvidenceArtifact)
  end
end
