# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Domain do
  @moduledoc """
  The Ash domain containing every `ash_compliance` resource, and the single
  supported way to call into them.

  Hosts include this domain in their Ash configuration:

      config :ash, ash_domains: [..., AshCompliance.Domain]

  There is deliberately no *wire* API layer on this domain — no JSON:API, no
  GraphQL, no LiveView. Wire exposure is the host's concern. "No API layer"
  does not mean "no code interfaces": every public action is exposed here as a
  `define`, and both hosts and this package's own internals (compiler,
  projector, OSCAL, testing helpers) call these interfaces rather than
  building raw `Ash.Query`/`Ash.create!` pipelines.

  Callers pass `actor:`, `tenant:` and `authorize?:` as options on each call.
  The package attaches no policies of its own (they are the host's to
  define), so by default these calls run authorized-but-unrestricted; see the
  README for the policy story and for the `authorize?: false` conventions this
  package uses in its trusted internal machinery.
  """

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource(AshCompliance.Resources.Catalog) do
      define(:create_catalog, action: :create)
      define(:get_catalog_by_id, action: :read, get_by: [:id])
      define(:catalogs_for_organization, action: :for_organization, args: [:organization_id])
    end

    resource(AshCompliance.Resources.CatalogVersion) do
      define(:create_catalog_version, action: :create)
      define(:get_catalog_version_by_id, action: :read, get_by: [:id])

      # A catalog with no published version yet exports with a nil version.
      define(:latest_catalog_version,
        action: :latest_for_catalog,
        args: [:catalog_id],
        not_found_error?: false
      )
    end

    resource(AshCompliance.Resources.Control) do
      define(:create_control, action: :create)
      define(:get_control_by_id, action: :read, get_by: [:id])
      define(:control_by_control_id, action: :by_control_id, args: [:control_id])
      define(:controls_for_catalog, action: :for_catalog, args: [:catalog_id])
    end

    resource(AshCompliance.Resources.ControlRevision) do
      define(:create_control_revision, action: :create)
      define(:activate_control_revision, action: :activate)
      define(:withdraw_control_revision, action: :withdraw)
      define(:get_control_revision_by_id, action: :read, get_by: [:id])

      define(:active_control_revisions, action: :active_for_control, args: [:control_id])
    end

    resource(AshCompliance.Resources.Profile) do
      define(:create_profile, action: :create)
      define(:get_profile_by_id, action: :read, get_by: [:id])
      define(:profiles_for_organization, action: :for_organization, args: [:organization_id])
    end

    resource(AshCompliance.Resources.ProfileRevision) do
      define(:create_profile_revision, action: :create)
      define(:get_profile_revision_by_id, action: :read, get_by: [:id])

      define(:latest_profile_revision,
        action: :latest_for_profile,
        args: [:profile_id],
        not_found_error?: false
      )

      define(:profile_revisions_for_profile, action: :for_profile, args: [:profile_id])
    end

    resource(AshCompliance.Resources.RuleSetRevision) do
      define(:draft_rule_set_revision, action: :draft)
      define(:validate_rule_set_revision, action: :validate)
      define(:approve_rule_set_revision, action: :approve)
      define(:activate_rule_set_revision, action: :activate)
      define(:retire_rule_set_revision, action: :retire)
      define(:revoke_rule_set_revision, action: :revoke)
      define(:get_rule_set_revision_by_id, action: :read, get_by: [:id])

      define(:active_rule_set_revisions,
        action: :active_for_organization,
        args: [:organization_id]
      )

      # Every revision for the organization, any status — the editor's
      # rule-set list, which must show drafts, not just what is live.
      define(:rule_set_revisions_for_organization,
        action: :for_organization,
        args: [:organization_id]
      )
    end

    resource(AshCompliance.Resources.PolicyBundle) do
      define(:compile_policy_bundle, action: :compile)
      define(:activate_policy_bundle, action: :activate)
      define(:retire_policy_bundle, action: :retire)
      define(:get_policy_bundle_by_id, action: :read, get_by: [:id])

      # Absence is meaningful: no active bundle yet reads as nil.
      define(:active_policy_bundle,
        action: :active_for_organization,
        args: [:organization_id],
        not_found_error?: false
      )

      # The most recent bundle regardless of status, so an operator who
      # reopens the editor between compile and activate can still resume.
      define(:latest_policy_bundle,
        action: :latest_for_organization,
        args: [:organization_id],
        not_found_error?: false
      )
    end

    resource(AshCompliance.Resources.TenantPolicySet) do
      define(:create_tenant_policy_set, action: :create)
      define(:set_active_bundle, action: :set_active_bundle)
      define(:get_tenant_policy_set_by_id, action: :read, get_by: [:id])

      # Absence is meaningful: an organization with no tenant policy set yet
      # reads as nil, not a NotFound error.
      define(:tenant_policy_set,
        action: :for_organization,
        args: [:organization_id],
        not_found_error?: false
      )
    end

    resource(AshCompliance.Resources.PolicyOverride) do
      define(:create_policy_override, action: :create)
      define(:get_policy_override_by_id, action: :read, get_by: [:id])

      define(:valid_policy_overrides,
        action: :valid_for_organization,
        args: [:organization_id, :now]
      )
    end

    resource(AshCompliance.Resources.ControlMapping) do
      define(:create_control_mapping, action: :create)
      define(:get_control_mapping_by_id, action: :read, get_by: [:id])
      define(:mapping_by_gap, action: :by_gap, args: [:gap, :organization_id])
    end

    resource(AshCompliance.Resources.Finding) do
      define(:get_finding_by_id, action: :read, get_by: [:id])
      define(:list_findings, action: :read)
      define(:findings_for_organization, action: :for_organization, args: [:organization_id])

      define(:noncompliant_findings,
        action: :noncompliant_for_organization,
        args: [:organization_id]
      )
    end

    resource(AshCompliance.Resources.ComplianceEvaluation) do
      define(:record_evaluation, action: :record)
      define(:get_evaluation_by_id, action: :read, get_by: [:id])
      define(:list_evaluations, action: :read)
      define(:evaluations_for_organization, action: :for_organization, args: [:organization_id])

      define(:evaluations_for_subject,
        action: :for_subject,
        args: [:organization_id, :subject_type, :subject_id]
      )
    end

    resource(AshCompliance.Resources.EvidenceArtifact) do
      define(:create_evidence_artifact, action: :create)
      define(:get_evidence_artifact_by_id, action: :read, get_by: [:id])
      define(:evidence_for_control, action: :for_control, args: [:organization_id, :control_id])
    end
  end
end
