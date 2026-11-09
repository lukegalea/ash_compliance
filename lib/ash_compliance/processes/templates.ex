# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.Templates do
  @moduledoc """
  The operator process templates this package ships.

  Each template is a BPMN document under `priv/processes/`. A host copies the
  documents it wants into its own tree, binds the candidate roles named in them
  to its own groups, publishes them through its process engine and cites the
  resulting file in its control file's `operating_process` column. The templates
  are generic: the roles are names (`approver`, `security_reviewer`), not
  people, and the routing questions go to the decisions shipped under
  `priv/decisions/`.

  ## What a template promises

    * Every approval step excludes the requester from its candidates and is
      followed by a business rule task that asks `compliance.separation_of_duties`
      whether approver and requester are different people. Anything but a
      `permit` ends the process as `refused`.
    * Every path that finishes ends in `compliance.record_completion`. An outcome
      that is not a completion (`rejected`, `refused`, `not_completed`,
      `recorded_only`) writes no evidence, so a stalled or refused process leaves
      the control reading as stale rather than as evidenced.
    * A process engine never decides: the shared decisions answer, and the
      actions named by `actions/0` do the work in the host.

  ## Fields

    * `:key` - the file stem and the process key suffix
    * `:name` - the human name
    * `:process_key` - `compliance.<key>`, the key the host publishes under
    * `:trigger` - `:schedule` or `:event`
    * `:frequency` - a `AshCompliance.Ownership.Frequency` name for a
      scheduled template, `nil` for an event-driven one
    * `:criteria` - the Trust Services criteria the process supports
    * `:approval?` - whether a human approval gates completion
    * `:file` - the path under `priv/`
  """

  alias AshCompliance.Ownership.{Criteria, Frequency}

  @actions ~w(compliance.open_record compliance.attach_evidence compliance.apply_decision
              compliance.notify compliance.record_completion)

  @decisions ~w(compliance.separation_of_duties compliance.triage_routing)

  # key, name, trigger, frequency, criteria, approval?
  @rows [
    {"effective_access_review", "Effective access review", :schedule, "quarterly",
     ~w(CC6.2 CC6.3), true},
    {"access_request", "Access request and privileged grant", :event, nil, ~w(CC6.1 CC6.2 CC6.3),
     true},
    {"break_glass", "Break-glass approval and follow-up review", :event, nil, ~w(CC6.1 CC8.1),
     true},
    {"impersonation", "Impersonation session approval", :event, nil, ~w(CC6.1), true},
    {"emergency_change_review", "Emergency change follow-up review", :event, nil, ~w(CC8.1),
     true},
    {"custody_cutover_approval", "Custody or authority cutover approval", :event, nil,
     ~w(CC6.3 CC8.1), true},
    {"divergence_signoff", "Divergence register sign-off", :event, nil, ~w(CC8.1), true},
    {"override_waiver_approval", "Override and waiver approval", :event, nil, ~w(CC4.2 CC5.3),
     true},
    {"log_alert_review", "Audit log and alert review", :schedule, "weekly", ~w(CC7.2), false},
    {"vulnerability_triage", "Vulnerability triage", :event, nil, ~w(CC7.1 CC4.2), false},
    {"incident_response", "Incident record, response and post-incident review", :event, nil,
     ~w(CC7.3 CC7.4 CC7.5), true},
    {"restore_test_attestation", "Restore test attestation", :schedule, "quarterly", ~w(A1.3),
     true},
    {"retention_disposal_approval", "Retention and disposal approval", :event, nil, ~w(C1.2),
     true},
    {"policy_review_acknowledgement", "Policy review and staff acknowledgement", :schedule,
     "annual", ~w(CC1.1 CC2.2 CC5.3), true},
    {"oversight_meeting", "Oversight meeting minutes and actions", :event, nil, ~w(CC1.2), true},
    {"training_attestation", "Training and role-accountability attestation", :schedule, "annual",
     ~w(CC1.4 CC1.5), true},
    {"risk_register_review", "Risk register review", :schedule, "monthly",
     ~w(CC3.1 CC3.2 CC3.3 CC3.4 CC5.1), true},
    {"vendor_review", "Vendor report review and complementary controls", :schedule, "annual",
     ~w(CC9.1 CC9.2), true},
    {"customer_notification", "Customer security notification", :event, nil, ~w(CC2.3), true}
  ]

  @templates Enum.map(@rows, fn {key, name, trigger, frequency, criteria, approval?} ->
               %{
                 key: key,
                 name: name,
                 process_key: "compliance." <> key,
                 trigger: trigger,
                 frequency: frequency,
                 criteria: criteria,
                 approval?: approval?,
                 file: "processes/" <> key <> ".bpmn"
               }
             end)

  @type t :: %{
          key: String.t(),
          name: String.t(),
          process_key: String.t(),
          trigger: :schedule | :event,
          frequency: String.t() | nil,
          criteria: [String.t()],
          approval?: boolean(),
          file: String.t()
        }

  @doc "Every template, in the order the plan lists them."
  @spec all() :: [t()]
  def all, do: @templates

  @doc "Looks a template up by file stem or by process key."
  @spec get(term()) :: t() | nil
  def get(key) when is_binary(key),
    do: Enum.find(@templates, &(&1.key == key or &1.process_key == key))

  def get(_), do: nil

  @doc "The action names the templates call. The host's action invoker implements them."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "The decision references the templates call. The host publishes them."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @doc "Absolute path of a template's BPMN document."
  @spec path(t() | String.t()) :: Path.t()
  def path(%{file: file}), do: Application.app_dir(:ash_compliance, Path.join("priv", file))

  def path(key) when is_binary(key),
    do: path(get(key) || raise(ArgumentError, "unknown template #{inspect(key)}"))

  @doc "The BPMN XML of a template."
  @spec xml(t() | String.t()) :: String.t()
  def xml(template_or_key), do: template_or_key |> path() |> File.read!()

  @doc "SHA-256 (hex) of the template document: the version a completion pins."
  @spec content_hash(t() | String.t()) :: String.t()
  def content_hash(template_or_key),
    do: template_or_key |> xml() |> AshCompliance.Ownership.Evidence.sha256()

  @doc """
  The reference a host's control file conventionally uses for a template it has
  copied to `priv/processes/` in its own tree.
  """
  @spec reference(t() | String.t()) :: String.t()
  def reference(%{key: key}), do: "file:priv/processes/" <> key <> ".bpmn"

  def reference(key) when is_binary(key),
    do: reference(get(key) || raise(ArgumentError, "unknown template #{inspect(key)}"))

  @doc """
  Faults in the catalogue itself: a criterion that is not in the catalogue, an
  unknown frequency, a scheduled template without a frequency, or a missing
  document. An empty list means the catalogue is well formed.
  """
  @spec faults() :: [String.t()]
  def faults do
    Enum.flat_map(@templates, fn t ->
      unknown =
        for id <- t.criteria, not Criteria.known?(id), do: "#{t.key}: unknown criterion #{id}"

      freq =
        cond do
          t.trigger == :schedule and not Frequency.valid?(t.frequency) ->
            ["#{t.key}: scheduled without a valid frequency"]

          t.trigger == :event and t.frequency != nil ->
            ["#{t.key}: event driven but has a frequency"]

          true ->
            []
        end

      file = if File.exists?(path(t)), do: [], else: ["#{t.key}: document is missing"]
      unknown ++ freq ++ file
    end)
  end
end
