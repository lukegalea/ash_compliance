# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OscalAssessmentResultsTest do
  @moduledoc """
  `AshCompliance.Oscal.AssessmentResults.build/2`: every document it builds is validated
  against NIST's official OSCAL 1.2.3 assessment-results schema, vendored with its
  licence in `test/support/oscal/1.2.3/`. The document never says `satisfied`, its
  identifiers are version 5 UUIDs derived from what they name, and its properties are in
  the namespace the caller chooses.
  """

  use AshCompliance.DataCase, async: false

  import AshCompliance.Test.OwnershipFixtures

  alias AshCompliance.Domain
  alias AshCompliance.Oscal.AssessmentResults
  alias AshCompliance.Ownership.{Evidence, Freshness, Package, Retention}
  alias AshCompliance.Resources.{EvidenceArtifact, Finding}
  alias AshCompliance.TestRepo

  @schema_path "test/support/oscal/1.2.3/oscal_assessment-results_schema.json"
  @schema_sha256 "4034e2032332dbf597e59e0646ec16c2c31df992962490371e91f47b219ff42c"
  @now ~U[2026-11-10 12:00:00.000000Z]
  @from ~U[2026-04-24 12:00:00.000000Z]
  @producer "module:Producer"
  @uuid5 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  setup do
    TestRepo.delete_all(Finding)
    TestRepo.delete_all(EvidenceArtifact)
    %{org: Ecto.UUID.generate()}
  end

  defp days_ago(days), do: DateTime.add(@now, -days * 86_400, :second)

  defp record!(org, control, days, opts \\ []) do
    {:ok, artifact} =
      Evidence.record(
        org,
        control,
        "content-#{System.unique_integer([:positive])}",
        Keyword.merge([producer: @producer, now: @now, collected_at: days_ago(days)], opts)
      )

    artifact
  end

  # A period with something of every kind in it: evidence hot and archived, an evidenced
  # criterion, unknown ones (one waived), a noncompliant finding, an unknown one, and the
  # host's own observation and finding.
  defp busy_sections!(org, opts \\ []) do
    record!(org, "CC6.1", 120, method: :test)
    record!(org, "CC6.1", 100, method: :interview)
    record!(org, "CC6.1", 1)
    {:ok, {:archived, _}} = Retention.archive(now: @now)

    Domain.create_policy_override!(
      %{
        organization_id: org,
        kind: :waive,
        rule_id: Freshness.rule_id("CC6.3"),
        reason: "documented exception",
        approver: "security-officer",
        requested_by: "ops-engineer",
        approved_at: days_ago(11),
        starts_at: days_ago(10),
        expires_at: DateTime.add(@now, 86_400, :second),
        compensating_controls: ["manual-review"]
      },
      authorize?: false
    )

    finding!(org, "CC7.2", :noncompliant, "a rule failed")
    finding!(org, "6.1-local", :unknown, nil)

    rows = with_row(rows(), "CC6.1", &Map.put(&1, "frequency", "annual"))

    {:ok, sections} =
      Package.sections(
        org,
        @from,
        @now,
        Keyword.merge(
          [
            controls_file: tmp_file("controls.json", Jason.encode!(%{"criteria" => rows})),
            generated_at: @now,
            extra_observations: [
              %{
                id: "host-check:#{org}",
                title: "A host check",
                description: "The host's own verification ran.",
                methods: [:test],
                collected: @now,
                props: %{"check-status" => "intact"},
                relevant_evidence: [%{href: "host.json", description: "The check's output."}]
              }
            ],
            extra_findings: [
              %{
                id: "host-finding:#{org}",
                title: "CC7.3: the host's check failed",
                description: "The host's check found a problem.",
                control_id: "CC7.3",
                reason: :fail,
                remarks: "Reported by the host."
              }
            ]
          ],
          opts
        )
      )

    sections
  end

  defp meta(org, extra \\ %{}) do
    Map.merge(%{organization_id: org, from: @from, to: @now, generated_at: @now}, extra)
  end

  describe "the vendored schema" do
    test "is the pinned release file" do
      assert @schema_path |> File.read!() |> sha256() == @schema_sha256
    end

    test "the validator refuses what the schema refuses", %{org: org} do
      doc = AssessmentResults.build(busy_sections!(org), meta(org))
      root = schema()
      assert {:ok, _} = JSV.validate(doc, root)

      # A version 7 UUID, as the database would issue: OSCAL requires 4 or 5.
      bad_uuid = put_in(doc, ["assessment-results", "uuid"], Ash.UUIDv7.generate())
      assert {:error, _} = JSV.validate(bad_uuid, root)

      # A control id that is not a token.
      [result] = doc["assessment-results"]["results"]

      bad_control =
        put_in(doc, ["assessment-results", "results"], [
          put_in(result, ["reviewed-controls", "control-selections"], [
            %{"include-controls" => [%{"control-id" => "6.1"}]}
          ])
        ])

      assert {:error, _} = JSV.validate(bad_control, root)
    end
  end

  describe "build/2" do
    test "builds valid OSCAL 1.2.3 for a busy period and for an empty one", %{org: org} do
      busy = AssessmentResults.build(busy_sections!(org), meta(org))
      assert :ok = validate(busy)

      empty_org = Ecto.UUID.generate()

      {:ok, empty} =
        Package.sections(empty_org, @from, @now,
          controls_file: "/nonexistent/controls.json",
          generated_at: @now
        )

      assert :ok = validate(AssessmentResults.build(empty, meta(empty_org)))
      assert busy["assessment-results"]["metadata"]["oscal-version"] == "1.2.3"
    end

    test "never says satisfied: unknown is other, noncompliant and the host's are fail",
         %{org: org} do
      doc = AssessmentResults.build(busy_sections!(org), meta(org))
      [result] = doc["assessment-results"]["results"]

      refute doc |> Jason.encode!() |> String.contains?(~s("satisfied"))

      statuses =
        Enum.map(result["findings"], &{&1["target"]["target-id"], &1["target"]["status"]})

      assert Enum.all?(statuses, fn {_, status} -> status["state"] == "not-satisfied" end)

      by_target = Map.new(statuses)
      assert by_target["CC7.2"]["reason"] == "fail"
      assert by_target["CC7.3"]["reason"] == "fail"
      assert by_target["CC6.2"]["reason"] == "other"
      # A rule set's own control id is carried as a token.
      assert by_target["_6.1-local"]["reason"] == "other"

      # Evidenced: observations, and no finding.
      refute Map.has_key?(by_target, "CC6.1")

      # Waived but still unknown: a finding that says so.
      cc63 = Enum.find(result["findings"], &(&1["target"]["target-id"] == "CC6.3"))
      assert cc63["description"] =~ "Silenced by a waiver"
    end

    test "observes each artifact collected in the period, with its method", %{org: org} do
      sections = busy_sections!(org)
      doc = AssessmentResults.build(sections, meta(org))
      [result] = doc["assessment-results"]["results"]

      in_period =
        for criterion <- sections.evidence["criteria"],
            artifact <- criterion["artifacts"],
            artifact["in_period"],
            do: artifact

      assert length(in_period) == 3

      for artifact <- in_period do
        observation =
          Enum.find(
            result["observations"],
            &(&1["uuid"] == AssessmentResults.uuid5("artifact:#{artifact["id"]}"))
          )

        assert observation["methods"] == [String.upcase(artifact["method"])]
      end

      assert Enum.any?(result["observations"], &(&1["methods"] == ["INTERVIEW"]))
      assert Enum.any?(result["observations"], &(&1["title"] == "A host check"))
    end

    test "identifiers are version 5 UUIDs derived from what they name", %{org: org} do
      sections = busy_sections!(org)
      doc = AssessmentResults.build(sections, meta(org))

      assert doc == AssessmentResults.build(sections, meta(org))
      # The organization, period and generation time default to the sections' own.
      assert doc == AssessmentResults.build(sections, %{})

      uuids = collect_uuids(doc)
      assert uuids != []
      assert Enum.all?(uuids, &Regex.match?(@uuid5, &1))
      assert length(Enum.uniq(uuids)) == length(uuids)

      assert AssessmentResults.uuid5("host-check:#{org}") in uuids

      later = AssessmentResults.build(sections, meta(org, %{generated_at: DateTime.add(@now, 1)}))
      refute later["assessment-results"]["uuid"] == doc["assessment-results"]["uuid"]
    end

    test "puts every property in the namespace given", %{org: org} do
      ns = "urn:example:audit"
      doc = AssessmentResults.build(busy_sections!(org), meta(org, %{namespace: ns}))
      assert :ok = validate(doc)

      namespaces = doc |> collect_props() |> Enum.map(& &1["ns"]) |> Enum.uniq()
      assert namespaces == [ns]

      default = AssessmentResults.build(busy_sections!(Ecto.UUID.generate()), meta(org))

      assert default |> collect_props() |> Enum.map(& &1["ns"]) |> Enum.uniq() ==
               [AssessmentResults.default_namespace()]
    end

    test "refuses a host finding that claims more than not-satisfied, and a malformed one",
         %{org: org} do
      sections = busy_sections!(org)
      [finding] = sections.extra_findings

      for reason <- [:pass, "satisfied", nil] do
        assert_raise ArgumentError, fn ->
          AssessmentResults.build(
            %{sections | extra_findings: [%{finding | reason: reason}]},
            meta(org)
          )
        end
      end

      [observation] = sections.extra_observations

      assert_raise ArgumentError, ~r/:collected/, fn ->
        AssessmentResults.build(
          %{sections | extra_observations: [Map.delete(observation, :collected)]},
          meta(org)
        )
      end

      assert_raise ArgumentError, ~r/method/, fn ->
        AssessmentResults.build(
          %{sections | extra_observations: [%{observation | methods: [:guess]}]},
          meta(org)
        )
      end
    end
  end

  defp finding!(org, control, status, explanation) do
    grain = %{organization_id: org, control_id: control, subject_type: "record", subject_id: "r"}
    {:ok, row} = Domain.upsert_finding_grain(grain, authorize?: false)

    {:ok, _} =
      Domain.apply_finding_ops(
        row,
        [
          {:set, :status, status},
          {:set, :first_seen_at, days_ago(5)},
          {:set, :last_seen_at, days_ago(1)},
          {:set, :explanation, explanation}
        ],
        authorize?: false
      )
  end

  defp collect_uuids(%{} = map) do
    own = for {"uuid", value} <- map, do: value
    own ++ Enum.flat_map(Map.values(map), &collect_uuids/1)
  end

  defp collect_uuids(list) when is_list(list), do: Enum.flat_map(list, &collect_uuids/1)
  defp collect_uuids(_), do: []

  defp collect_props(%{} = map) do
    own = map |> Map.get("props", []) |> List.wrap()
    own ++ Enum.flat_map(Map.drop(map, ["props"]) |> Map.values(), &collect_props/1)
  end

  defp collect_props(list) when is_list(list), do: Enum.flat_map(list, &collect_props/1)
  defp collect_props(_), do: []

  defp validate(doc) do
    case JSV.validate(doc, schema()) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, JSV.normalize_error(error)}
    end
  end

  # The official schema, read unchanged. Each definition repeats its own location as its
  # `$id`, which JSV refuses as an identifier: such an `$id` is dropped, which changes
  # nothing it resolves to, and any other `$id` fails the test.
  defp schema do
    raw = @schema_path |> File.read!() |> Jason.decode!()

    definitions =
      Map.new(raw["definitions"], fn
        {name, %{"$id" => id} = definition} ->
          if id != "#/definitions/" <> name, do: flunk("unexpected $id #{id} on #{name}")
          {name, Map.delete(definition, "$id")}

        other ->
          other
      end)

    raw |> Map.put("definitions", definitions) |> JSV.build!(formats: true)
  end

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
end
