# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Oscal.AssessmentResults do
  @moduledoc """
  An OSCAL 1.2.3 assessment-results document built from the sections
  `AshCompliance.Ownership.Package.sections/4` assembles.

  One result covers the period. Its reviewed controls are the criteria in scope, and it
  carries:

    * an **observation** for every evidence artifact collected in the period (its method
      is the artifact's assessment method), one for each criterion's freshness at the end
      of the period, and one for each of the host's `extra_observations`;
    * a **finding** for every criterion whose freshness at the end of the period is
      unknown, for every compliance finding open in the period that is not compliant,
      and one for each of the host's `extra_findings`.

  The package's test suite validates every document it builds against NIST's official
  assessment-results schema.

  ## Never "satisfied"

  OSCAL's objective status is `satisfied` or `not-satisfied`. This document never says
  `satisfied`: the package answers owned, evidenced or unknown, and only an auditor
  attests. An evidenced criterion therefore has observations and no finding; an unknown
  one has a `not-satisfied` finding whose reason is `other`, because unknown is never a
  pass; a noncompliant one has a `not-satisfied` finding whose reason is `fail`. A host's
  extra finding is `not-satisfied` too, with reason `fail` or `other`.

  ## Identifiers

  OSCAL requires version 4 or 5 UUIDs. Every identifier here is a version 5 UUID derived
  from what it names (`uuid5/1`): the artifact's id, the criterion, the organization,
  period and generation time, or the `:id` a host gives an extra observation or finding.
  The same inputs always give the same document.

  ## Properties

  Facts OSCAL has no field for travel as properties in one namespace, `meta.namespace`
  (default `"urn:ash-compliance:assessment-results"`).

  ## Files beside the document

  `import-ap` and the observations' `relevant-evidence` point at the sections as files
  beside the document: `controls.json` (the criteria in scope and the control file's
  row for each) and `evidence.json` (each artifact, with its content when it is text).
  A host that writes the package to files uses those names.
  """

  @oscal_version "1.2.3"
  @default_namespace "urn:ash-compliance:assessment-results"
  # RFC 4122's URL namespace: the derived names are URNs.
  @uuid_namespace "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
  @token ~r/^(\p{L}|_)(\p{L}|\p{N}|[.\-_])*$/u
  @methods ~w(EXAMINE INTERVIEW TEST UNKNOWN)
  @reasons ~w(fail other)

  @typedoc """
  A host observation (`extra_observations:`), a plain map with atom keys:

    * `:id` - **required**. The name its UUID is derived from; unique in the document.
    * `:title`, `:description` - **required** strings.
    * `:methods` - **required**. `:examine`, `:interview`, `:test` or `:unknown`, as
      atoms or strings.
    * `:collected` - **required**. A `DateTime` or an ISO 8601 string.
    * `:props` - optional `%{name => value}`, emitted in the document's namespace.
    * `:relevant_evidence` - optional list of `%{href: ..., description: ...}`.
  """
  @type extra_observation :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t(),
          required(:methods) => [atom() | String.t()],
          required(:collected) => DateTime.t() | String.t(),
          optional(:props) => map(),
          optional(:relevant_evidence) => [map()]
        }

  @typedoc """
  A host finding (`extra_findings:`), a plain map with atom keys:

    * `:id` - **required**. The name its UUID is derived from; unique in the document.
    * `:title`, `:description` - **required** strings.
    * `:control_id` - **required**. The objective it is about.
    * `:reason` - **required**. `:fail` or `:other`; the state is always `not-satisfied`.
    * `:remarks` - optional string on the target's status.
    * `:props` - optional `%{name => value}`, emitted in the document's namespace.
  """
  @type extra_finding :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t(),
          required(:control_id) => String.t(),
          required(:reason) => :fail | :other | String.t(),
          optional(:remarks) => String.t(),
          optional(:props) => map()
        }

  @doc "The OSCAL version the document declares and is validated against."
  @spec oscal_version() :: String.t()
  def oscal_version, do: @oscal_version

  @doc "The default namespace of the document's own properties."
  @spec default_namespace() :: String.t()
  def default_namespace, do: @default_namespace

  @doc """
  The assessment-results document for `sections`, as a JSON-ready map with string keys.

  `sections` is what `AshCompliance.Ownership.Package.sections/4` returns. `meta`:

    * `:organization_id`, `:from`, `:to`, `:generated_at` - default to the sections'
      own (`organization_id`, `period.from`, `period.to`, `generated_at`), and are
      required when the sections do not carry them.
    * `:as_of` - when freshness was evaluated. Default: `sections.period.as_of`.
    * `:namespace` - the properties' namespace. Default `default_namespace/0`.
    * `:title` - the document's title. Default `"Assessment results <from> to <to>"`.
    * `:result_title` - the result's title. Default
      `"Evidence, freshness and findings"`.

  Raises `ArgumentError` for an extra observation or finding that is malformed, or one
  whose reason would claim anything but `not-satisfied`.
  """
  @spec build(map(), map()) :: map()
  def build(sections, meta) do
    meta = normalize_meta(sections, meta)
    ns = meta.namespace

    package =
      "#{meta.organization_id}:#{iso(meta.from)}:#{iso(meta.to)}:#{iso(meta.generated_at)}"

    observations =
      artifact_observations(sections.evidence, ns) ++
        freshness_observations(sections.evidence, meta) ++
        Enum.map(Map.get(sections, :extra_observations, []), &extra_observation(&1, ns))

    findings =
      freshness_findings(sections.evidence) ++
        compliance_findings(sections.findings, ns) ++
        Enum.map(Map.get(sections, :extra_findings, []), &extra_finding(&1, ns))

    result =
      %{
        "uuid" => uuid5("result:" <> package),
        "title" => meta.result_title,
        "description" =>
          "Assessment results for one organization over [#{iso(meta.from)}, #{iso(meta.to)}). " <>
            "Freshness is evaluated at #{iso(meta.as_of)}.",
        "start" => iso(meta.from),
        "end" => iso(meta.to),
        "props" => [prop(ns, "organization", meta.organization_id)],
        "reviewed-controls" => %{
          "control-selections" => [
            %{
              "include-controls" =>
                Enum.map(sections.controls["criteria"], &%{"control-id" => token(&1["id"])})
            }
          ]
        },
        "observations" => observations,
        "findings" => findings,
        "remarks" =>
          "No objective is reported as satisfied. Criteria are owned, evidenced or unknown; " <>
            "an attestation is an auditor's."
      }
      |> drop_empty()

    %{
      "assessment-results" => %{
        "uuid" => uuid5("assessment-results:" <> package),
        "metadata" => %{
          "title" => meta.title,
          "last-modified" => iso(meta.generated_at),
          "version" => "1",
          "oscal-version" => @oscal_version
        },
        "import-ap" => %{
          "href" => "controls.json",
          "remarks" =>
            "No assessment plan is published. The criteria in scope and the control " <>
              "file's row for each are in controls.json beside this document."
        },
        "results" => [result]
      }
    }
  end

  defp normalize_meta(sections, meta) do
    period = Map.get(sections, :period, %{})

    meta =
      %{
        organization_id: Map.get(sections, :organization_id),
        from: Map.get(period, :from),
        to: Map.get(period, :to),
        generated_at: Map.get(sections, :generated_at)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.merge(Map.new(meta))

    for key <- [:organization_id, :from, :to, :generated_at], is_nil(Map.get(meta, key)) do
      raise ArgumentError, "build/2 needs #{inspect(key)} in meta"
    end

    meta
    |> Map.put_new_lazy(:as_of, fn ->
      Map.get(period, :as_of) || Enum.min([meta.to, meta.generated_at], DateTime)
    end)
    |> Map.put_new(:namespace, @default_namespace)
    |> Map.put_new(:title, "Assessment results #{iso(meta.from)} to #{iso(meta.to)}")
    |> Map.put_new(:result_title, "Evidence, freshness and findings")
  end

  # --- observations ----------------------------------------------------------

  defp artifact_observations(evidence, ns) do
    for criterion <- evidence["criteria"],
        artifact <- criterion["artifacts"],
        artifact["in_period"] do
      %{
        "uuid" => uuid5("artifact:#{artifact["id"]}"),
        "title" => "Evidence for #{criterion["id"]}",
        "description" =>
          "Artifact #{artifact["id"]} from #{artifact["collector"]} (#{artifact["media_type"]}), " <>
            "sha256 #{artifact["sha256"]}; integrity #{artifact["integrity"]}.",
        "props" => [
          prop(ns, "criterion", criterion["id"]),
          prop(ns, "integrity", artifact["integrity"]),
          prop(ns, "location", artifact["location"])
        ],
        "methods" => [String.upcase(artifact["method"])],
        "collected" => artifact["collected_at"],
        "relevant-evidence" => [
          %{
            "href" => "evidence.json",
            "description" =>
              "Artifact #{artifact["id"]} in evidence.json, with its content when it is text."
          }
        ]
      }
    end
  end

  defp freshness_observations(evidence, meta) do
    for criterion <- evidence["criteria"], freshness = criterion["freshness"], freshness do
      %{
        "uuid" =>
          uuid5("freshness:#{meta.organization_id}:#{criterion["id"]}:#{iso(meta.as_of)}"),
        "title" => "Freshness of #{criterion["id"]}",
        "description" => "#{freshness["state"]}: #{freshness["detail"]}",
        "props" => [
          prop(meta.namespace, "criterion", criterion["id"]),
          prop(meta.namespace, "freshness-state", freshness["state"])
        ],
        "methods" => ["EXAMINE"],
        "collected" => iso(meta.as_of)
      }
    end
  end

  defp extra_observation(observation, ns) do
    observation = fetch_all!(observation, [:id, :title, :description, :methods, :collected])

    %{
      "uuid" => uuid5(observation.id),
      "title" => observation.title,
      "description" => observation.description,
      "props" => props(observation, ns),
      "methods" => Enum.map(List.wrap(observation.methods), &method!/1),
      "collected" => iso(observation.collected),
      "relevant-evidence" =>
        observation
        |> Map.get(:relevant_evidence, [])
        |> Enum.map(fn evidence ->
          drop_nil(%{
            "href" => fetch!(evidence, :href),
            "description" => Map.get(evidence, :description)
          })
        end)
    }
    |> drop_empty()
  end

  defp method!(method) do
    upper = method |> to_string() |> String.upcase()

    if upper in @methods,
      do: upper,
      else: raise(ArgumentError, "an observation method is one of #{inspect(@methods)}")
  end

  # --- findings --------------------------------------------------------------

  defp freshness_findings(evidence) do
    for criterion <- evidence["criteria"],
        freshness = criterion["freshness"],
        freshness && freshness["state"] == "unknown" do
      waiver =
        case freshness["silenced_by"] do
          %{} = by -> " Silenced by a waiver until #{by["expires_at"]}."
          _ -> ""
        end

      %{
        "uuid" => uuid5("freshness-finding:#{criterion["id"]}:#{freshness["detail"]}"),
        "title" => "#{criterion["id"]}: evidence is unknown",
        "description" => "#{freshness["reason"]}: #{freshness["detail"]}.#{waiver}",
        "target" =>
          target(
            criterion["id"],
            "other",
            "Unknown is never a pass: no fresh evidence was found."
          )
      }
    end
  end

  defp compliance_findings(findings, ns) do
    for finding <- findings["findings"],
        finding["subject_type"] != "evidence_freshness",
        finding["status"] != "compliant" do
      reason = if finding["status"] == "noncompliant", do: "fail", else: "other"

      %{
        "uuid" => uuid5("finding:#{finding["id"]}"),
        "title" => "#{finding["control_id"]}: #{finding["status"]}",
        "description" => finding_description(finding),
        "props" => [
          prop(ns, "finding-id", finding["id"]),
          prop(ns, "control", finding["control_id"])
        ],
        "target" => target(finding["control_id"], reason, "Projected compliance finding.")
      }
    end
  end

  defp finding_description(%{"explanation" => text}) when is_binary(text) and text != "",
    do: text

  defp finding_description(finding),
    do: "#{finding["status"]} for #{finding["subject_type"]} #{finding["subject_id"]}."

  defp extra_finding(finding, ns) do
    finding = fetch_all!(finding, [:id, :title, :description, :control_id, :reason])
    reason = to_string(finding.reason)

    unless reason in @reasons do
      raise ArgumentError,
            "an extra finding's reason is :fail or :other (its state is always " <>
              "not-satisfied), got: #{inspect(finding.reason)}"
    end

    %{
      "uuid" => uuid5(finding.id),
      "title" => finding.title,
      "description" => finding.description,
      "props" => props(finding, ns),
      "target" => target(finding.control_id, reason, Map.get(finding, :remarks))
    }
    |> drop_empty()
  end

  defp target(control_id, reason, remarks) do
    %{
      "type" => "objective-id",
      "target-id" => token(control_id),
      "status" =>
        drop_nil(%{"state" => "not-satisfied", "reason" => reason, "remarks" => remarks})
    }
  end

  # --- helpers ---------------------------------------------------------------

  defp prop(ns, name, value), do: %{"name" => name, "ns" => ns, "value" => to_string(value)}

  defp props(map, ns) do
    map
    |> Map.get(:props, %{})
    |> Enum.sort()
    |> Enum.map(fn {name, value} -> prop(ns, to_string(name), value) end)
  end

  defp fetch_all!(map, keys) when is_map(map) do
    Enum.each(keys, &fetch!(map, &1))
    map
  end

  defp fetch_all!(other, _keys),
    do: raise(ArgumentError, "an extra observation or finding is a map, got: #{inspect(other)}")

  defp fetch!(map, key) do
    case Map.get(map, key) do
      nil -> raise ArgumentError, "#{inspect(key)} is required in #{inspect(map)}"
      "" -> raise ArgumentError, "#{inspect(key)} is required in #{inspect(map)}"
      value -> value
    end
  end

  @doc """
  `id` as an OSCAL token. A control identifier that is not one (a rule set's own id may
  start with a digit) is carried with its offending characters replaced, and a leading
  underscore when it would still start with something other than a letter.
  """
  @spec token(String.t()) :: String.t()
  def token(id) do
    if Regex.match?(@token, id) do
      id
    else
      cleaned = String.replace(id, ~r/[^\p{L}\p{N}._-]/u, "_")
      if Regex.match?(@token, cleaned), do: cleaned, else: "_" <> cleaned
    end
  end

  defp drop_empty(map), do: Map.reject(map, fn {_key, value} -> value == [] end)
  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @doc "A version 5 UUID for `name` (RFC 4122, SHA-1, the URL namespace)."
  @spec uuid5(String.t()) :: String.t()
  def uuid5(name) do
    <<a::48, _version::4, b::12, _variant::2, c::62>> =
      binary_part(:crypto.hash(:sha, Ecto.UUID.dump!(@uuid_namespace) <> name), 0, 16)

    Ecto.UUID.load!(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(at) when is_binary(at), do: at
end
