# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Criteria do
  @moduledoc """
  The SOC 2 (2017) Trust Services Criteria as data: 61 identifiers, each with
  a category and a short title written for this package.

  The titles paraphrase what each criterion is about so a reader can find
  their way; they are not the published criteria text. The catalogue is fixed
  and a host cannot remove an entry. A host chooses which categories are in
  its audit (`AshCompliance.Ownership.Check`), never which criteria exist
  within a category.

  Categories:

    * `:security` - the common criteria, `CC1` to `CC9`
    * `:availability` - `A1`
    * `:processing_integrity` - `PI1`
    * `:confidentiality` - `C1`
    * `:privacy` - `P1` to `P8`
  """

  @type category ::
          :security | :availability | :processing_integrity | :confidentiality | :privacy
  @type t :: %{id: String.t(), category: category(), title: String.t()}

  @rows [
    {"CC1.1", :security, "Commitment to integrity and ethical values"},
    {"CC1.2", :security, "Independent oversight of internal control"},
    {"CC1.3", :security, "Structures, reporting lines and authorities"},
    {"CC1.4", :security, "Attracting, developing and retaining competent people"},
    {"CC1.5", :security, "Individuals held accountable for their control duties"},
    {"CC2.1", :security, "Relevant, quality information supports control"},
    {"CC2.2", :security, "Internal communication of control responsibilities"},
    {"CC2.3", :security, "Communication with outside parties"},
    {"CC3.1", :security, "Objectives clear enough to assess risk against"},
    {"CC3.2", :security, "Risks identified and analysed"},
    {"CC3.3", :security, "Fraud potential considered in risk assessment"},
    {"CC3.4", :security, "Significant changes assessed for control impact"},
    {"CC4.1", :security, "Ongoing and separate evaluations of controls"},
    {"CC4.2", :security, "Deficiencies communicated and corrected"},
    {"CC5.1", :security, "Control activities selected to reduce risk"},
    {"CC5.2", :security, "General technology controls selected"},
    {"CC5.3", :security, "Controls deployed through policy and procedure"},
    {"CC6.1", :security, "Logical access controls over information assets"},
    {"CC6.2", :security, "User registration, authorization and removal"},
    {"CC6.3", :security, "Access granted, changed and revoked by role"},
    {"CC6.4", :security, "Physical access restricted"},
    {"CC6.5", :security, "Assets and data disposed of securely"},
    {"CC6.6", :security, "Protection against threats from outside the boundary"},
    {"CC6.7", :security, "Data in transit and removable media protected"},
    {"CC6.8", :security, "Malicious software prevented or detected"},
    {"CC7.1", :security, "Configuration and vulnerability monitoring"},
    {"CC7.2", :security, "Monitoring for anomalies and security events"},
    {"CC7.3", :security, "Events evaluated to decide whether they are incidents"},
    {"CC7.4", :security, "Incident response"},
    {"CC7.5", :security, "Recovery from incidents"},
    {"CC8.1", :security, "Changes authorized, tested and approved"},
    {"CC9.1", :security, "Business disruption risk mitigated"},
    {"CC9.2", :security, "Vendor and partner risk managed"},
    {"A1.1", :availability, "Capacity monitored and managed"},
    {"A1.2", :availability, "Environmental protection, backup and recovery infrastructure"},
    {"A1.3", :availability, "Recovery plans tested"},
    {"PI1.1", :processing_integrity, "Processing specifications defined and used"},
    {"PI1.2", :processing_integrity, "Input checks"},
    {"PI1.3", :processing_integrity, "Processing checks"},
    {"PI1.4", :processing_integrity, "Output checks"},
    {"PI1.5", :processing_integrity, "Stored items protected"},
    {"C1.1", :confidentiality, "Confidential information identified and protected"},
    {"C1.2", :confidentiality, "Confidential information disposed of"},
    {"P1.1", :privacy, "Privacy notice given"},
    {"P2.1", :privacy, "Choice and consent"},
    {"P3.1", :privacy, "Personal information collected for stated purposes"},
    {"P3.2", :privacy, "Explicit consent for sensitive personal information"},
    {"P4.1", :privacy, "Use limited to stated purposes"},
    {"P4.2", :privacy, "Retention of personal information"},
    {"P4.3", :privacy, "Disposal of personal information"},
    {"P5.1", :privacy, "Individuals can access their information"},
    {"P5.2", :privacy, "Individuals can correct their information"},
    {"P6.1", :privacy, "Disclosure to third parties authorized"},
    {"P6.2", :privacy, "Authorized disclosures recorded"},
    {"P6.3", :privacy, "Unauthorized disclosures recorded"},
    {"P6.4", :privacy, "Third parties held to privacy commitments"},
    {"P6.5", :privacy, "Third parties report incidents to the entity"},
    {"P6.6", :privacy, "Breach notification"},
    {"P6.7", :privacy, "Accounting of disclosures available"},
    {"P7.1", :privacy, "Personal information kept accurate and complete"},
    {"P8.1", :privacy, "Privacy complaints handled and compliance monitored"}
  ]

  @criteria Enum.map(@rows, fn {id, category, title} ->
              %{id: id, category: category, title: title}
            end)

  @categories [:security, :availability, :processing_integrity, :confidentiality, :privacy]

  @doc "Every criterion, in catalogue order."
  @spec all() :: [t()]
  def all, do: @criteria

  @doc "The criteria in the given categories (a category or a list of them)."
  @spec in_categories(category() | [category()]) :: [t()]
  def in_categories(categories) do
    wanted = List.wrap(categories)
    Enum.filter(@criteria, &(&1.category in wanted))
  end

  @doc "All category names."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "All criterion identifiers."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@criteria, & &1.id)

  @doc "Looks a criterion up by identifier."
  @spec get(String.t()) :: t() | nil
  def get(id) when is_binary(id), do: Enum.find(@criteria, &(&1.id == id))
  def get(_), do: nil

  @doc "True when the identifier is in the catalogue."
  @spec known?(term()) :: boolean()
  def known?(id), do: get(id) != nil
end
