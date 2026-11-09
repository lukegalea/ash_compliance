# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.AccessReviewTest do
  @moduledoc """
  The effective-access review. A campaign merges its sources into one row per
  person; a source that errors or lists nobody makes it incomplete; decisions
  are append-only and sealed; a campaign closes only when it is complete,
  decided, intact and signed off by someone other than the person who opened it.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.AccessReview
  alias AshCompliance.AccessReview.Merge
  alias AshCompliance.Domain
  alias AshCompliance.Processes.Approval
  alias AshCompliance.Resources.{AccessReviewCampaign, AccessReviewDecision, AccessReviewRow}
  alias AshCompliance.Test.ReviewSources, as: S
  alias AshCompliance.TestRepo

  @collector "file:priv/processes/effective_access_review.bpmn"
  @process "compliance.effective_access_review"

  setup do
    %{org: Ecto.UUID.generate()}
  end

  defp open(org, sources, opts \\ []) do
    AccessReview.open(
      org,
      %{name: "Quarterly", period: "2026-Q4", opened_by: "owner@example.test"},
      sources,
      opts
    )
  end

  defp open!(org, sources, opts \\ []) do
    {:ok, campaign} = open(org, sources, opts)
    campaign
  end

  defp rows(campaign) do
    campaign.id
    |> Domain.access_review_rows_for_campaign!(authorize?: false)
    |> Map.new(&{&1.person_key, &1})
  end

  defp decisions(campaign),
    do: Domain.access_review_decisions_for_campaign!(campaign.id, authorize?: false)

  defp decide_all!(campaign, reviewer \\ "reviewer@example.test") do
    for {_key, row} <- rows(campaign) do
      {:ok, _} = AccessReview.decide(row.id, reviewer, :keep, "ok")
    end
  end

  defp close(campaign, closer, opts \\ []) do
    AccessReview.close(campaign.id, closer, Keyword.merge([collector: @collector], opts))
  end

  defp reload(campaign),
    do: Domain.get_access_review_campaign_by_id!(campaign.id, authorize?: false)

  defp attempts(org, subject), do: Approval.attempts_for!(org, @process, subject)

  defp evidence(org, control), do: Domain.evidence_for_control!(org, control, authorize?: false)

  describe "merging sources" do
    test "one effective-access row per person across every source", %{org: org} do
      campaign = open!(org, [S.App, S.Legacy])
      assert campaign.status == :open
      assert campaign.source_ids == ["app", "legacy"]

      rows = rows(campaign)
      assert Map.keys(rows) == ["alice@example.test", "bob@example.test", "carol@example.test"]
      assert rows["alice@example.test"].sources == ["app"]
      assert rows["carol@example.test"].sources == ["legacy"]

      bob = rows["bob@example.test"]
      assert bob.sources == ["app", "legacy"]
      assert Map.keys(bob.entitlements) == ["app", "legacy"]
      assert [%{"ref" => "role:viewer", "scope" => "tenant-1"}] = bob.entitlements["app"]
      assert [%{"ref" => "rbac:pm"}] = bob.entitlements["legacy"]
      assert bob.entitlement_digest == Merge.digest(bob.entitlements)
    end

    test "each source's answer is recorded on the campaign", %{org: org} do
      campaign = open!(org, [S.App, S.Legacy])

      assert %{"status" => "ok", "count" => 2} = campaign.source_results["app"]
      assert %{"status" => "ok", "count" => 2} = campaign.source_results["legacy"]
    end

    test "the merge does not depend on the order sources are listed", %{org: org} do
      a =
        rows(open!(org, [S.App, S.Legacy])) |> Map.new(fn {k, r} -> {k, r.entitlement_digest} end)

      b =
        rows(open!(org, [S.Legacy, S.App])) |> Map.new(fn {k, r} -> {k, r.entitlement_digest} end)

      assert a == b
    end

    test "sources receive the organization, the time and their own options", %{org: org} do
      defmodule Probe do
        @moduledoc false
        @behaviour AshCompliance.AccessReview.Source
        def id, do: "probe"

        def entries(%{organization_id: org, as_of: %DateTime{}, options: %{"k" => "v"}}),
          do: {:ok, [%{person_key: org, grants: [%{ref: "ok"}]}]}

        def entries(_), do: {:error, :wrong_context}
      end

      campaign = open!(org, [Probe], source_options: %{"probe" => %{"k" => "v"}})
      assert campaign.status == :open
    end
  end

  describe "a source that does not give a usable answer makes the campaign incomplete" do
    for {name, module, status} <- [
          {"errored", S.Errored, "errored"},
          {"empty", S.Empty, "empty"},
          {"raising", S.Raising, "errored"},
          {"exiting", S.Exiting, "errored"},
          {"malformed", S.Malformed, "malformed"},
          {"listing a person with no grants", S.NoGrants, "malformed"},
          {"returning entries that are not a list", S.NotAList, "malformed"},
          {"returning something that is not a result", S.BadReturn, "malformed"}
        ] do
      @module module
      @status status

      test "#{name}", %{org: org} do
        campaign = open!(org, [S.App, @module])

        assert campaign.status == :incomplete
        assert %{"status" => @status} = campaign.source_results[@module.id()]
        assert %{"status" => "ok"} = campaign.source_results["app"]
      end
    end

    test "a source that times out", %{org: org} do
      campaign = open!(org, [S.App, S.Slow], source_timeout: 50)
      assert campaign.status == :incomplete

      assert %{"status" => "errored", "detail" => "timed out after 50ms"} =
               campaign.source_results["slow"]
    end

    test "the only source is empty: no rows, incomplete, never an empty pass", %{org: org} do
      campaign = open!(org, [S.Empty])
      assert campaign.status == :incomplete
      assert rows(campaign) == %{}
      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "incomplete"
      assert reload(campaign).status == :incomplete
    end

    test "the rows from the sources that answered are kept for investigation", %{org: org} do
      campaign = open!(org, [S.App, S.Errored])
      assert Map.keys(rows(campaign)) == ["alice@example.test", "bob@example.test"]
    end

    test "an incomplete campaign accepts no decisions", %{org: org} do
      campaign = open!(org, [S.App, S.Errored])
      row = rows(campaign)["alice@example.test"]

      assert {:error, error} = AccessReview.decide(row.id, "reviewer@example.test", :keep, nil)
      assert Exception.message(error) =~ "incomplete"
      assert decisions(campaign) == []
    end

    test "an incomplete campaign cannot be closed, naming the failed source", %{org: org} do
      campaign = open!(org, [S.App, S.Errored])

      assert {:error, error} = close(campaign, "closer@example.test")
      message = Exception.message(error)
      assert message =~ "incomplete"
      assert message =~ "errored errored"
      assert reload(campaign).status == :incomplete
      assert evidence(org, "CC6.2") == []
    end
  end

  describe "opening is refused" do
    test "with no sources", %{org: org} do
      assert {:error, :no_sources} = open(org, [])
      assert {:error, :no_sources} = open(org, nil)
    end

    test "with a repeated source id", %{org: org} do
      assert {:error, :duplicate_source} = open(org, [S.App, S.SameIdAsApp])
    end

    test "with a module that is not a source", %{org: org} do
      assert {:error, {:invalid_source, String}} = open(org, [S.App, String])
      assert {:error, {:invalid_source, NoSuchModule}} = open(org, [NoSuchModule])
      assert {:error, {:invalid_source, "app"}} = open(org, ["app"])
    end

    test "without a name, a period or an opener", %{org: org} do
      for key <- [:name, :period, :opened_by] do
        attrs = Map.delete(%{name: "Q", period: "2026-Q4", opened_by: "o"}, key)
        assert {:error, _} = AccessReview.open(org, attrs, [S.App])
      end
    end
  end

  describe "the status is derived, never chosen" do
    test "a caller cannot set it", %{org: org} do
      assert {:error, _} =
               Domain.open_access_review_campaign(
                 %{
                   organization_id: org,
                   name: "Q",
                   period: "p",
                   opened_by: "o",
                   opened_at: DateTime.utc_now(),
                   status: :open,
                   source_ids: ["a"],
                   source_results: %{"a" => %{"status" => "errored"}}
                 },
                 authorize?: false
               )
    end

    test "results that are missing, extra or not ok leave it incomplete", %{org: org} do
      base = %{
        organization_id: org,
        name: "Q",
        period: "p",
        opened_by: "o",
        opened_at: DateTime.utc_now()
      }

      for {ids, results} <- [
            {[], %{}},
            {["a"], %{}},
            {["a"], %{"a" => %{"status" => "empty"}}},
            {["a"], %{"a" => %{"status" => "ok"}, "b" => %{"status" => "ok"}}},
            {["a", "a"], %{"a" => %{"status" => "ok"}}},
            {["a"], %{"a" => "ok"}},
            {["a"], %{"a" => %{}}}
          ] do
        {:ok, campaign} =
          Domain.open_access_review_campaign(
            Map.merge(base, %{source_ids: ids, source_results: results}),
            authorize?: false
          )

        assert campaign.status == :incomplete,
               "expected incomplete for #{inspect({ids, results})}"
      end
    end
  end

  describe "decisions" do
    test "are sealed and bound to the row they were made on", %{org: org} do
      campaign = open!(org, [S.App, S.Legacy])
      row = rows(campaign)["bob@example.test"]

      assert {:ok, decision} =
               AccessReview.decide(row.id, "reviewer@example.test", :revoke, "left the team")

      assert decision.decision == :revoke
      assert decision.entitlement_digest == row.entitlement_digest
      assert decision.organization_id == org
      assert AccessReview.Seal.valid?(decision)

      assert [%{permitted_reason: "different_people"}] =
               for(a <- attempts(org, row.id), do: %{permitted_reason: a.reason})
    end

    test "a reviewer cannot decide on their own access, and the attempt is recorded", %{org: org} do
      campaign = open!(org, [S.App, S.Legacy])
      row = rows(campaign)["alice@example.test"]

      assert {:error, error} = AccessReview.decide(row.id, "Alice@example.test", :keep, "me")
      assert Exception.message(error) =~ "separation of duties"
      assert Exception.message(error) =~ "self_approval"
      assert decisions(campaign) == []

      assert [%{outcome: :refused, reason: "self_approval", requester_id: "alice@example.test"}] =
               attempts(org, row.id)
    end

    test "a reviewer cannot decide through a delegation from the person under review", %{org: org} do
      campaign = open!(org, [S.App, S.Legacy])
      row = rows(campaign)["alice@example.test"]

      assert {:error, error} =
               AccessReview.decide(row.id, "dave@example.test", :keep, "on behalf", [
                 "alice@example.test"
               ])

      assert Exception.message(error) =~ "delegated_self_approval"
      assert decisions(campaign) == []
      assert [%{outcome: :refused, reason: "delegated_self_approval"}] = attempts(org, row.id)
    end

    test "an unrecorded delegation chain or a blank reviewer is refused", %{org: org} do
      campaign = open!(org, [S.App, S.Legacy])
      row = rows(campaign)["alice@example.test"]

      assert {:error, _} = AccessReview.decide(row.id, "dave@example.test", :keep, nil, nil)
      assert {:error, _} = AccessReview.decide(row.id, "", :keep, nil)
      assert {:error, _} = AccessReview.decide(row.id, "   ", :keep, nil)
      assert {:error, _} = AccessReview.decide(row.id, "dave@example.test", :maybe, nil)
      assert decisions(campaign) == []
    end

    test "cannot be bound to a row of another campaign", %{org: org} do
      one = open!(org, [S.App])
      two = open!(org, [S.App])
      row = rows(one)["alice@example.test"]

      assert {:error, error} =
               Domain.record_access_review_decision(
                 %{campaign_id: two.id, row_id: row.id, reviewer_id: "dave", decision: :keep},
                 authorize?: false
               )

      assert Exception.message(error) =~ "does not belong"
    end

    test "cannot take the organization or the digest from the caller", %{org: org} do
      campaign = open!(org, [S.App])
      row = rows(campaign)["alice@example.test"]

      assert {:error, _} =
               Domain.record_access_review_decision(
                 %{
                   campaign_id: campaign.id,
                   row_id: row.id,
                   reviewer_id: "dave",
                   decision: :keep,
                   organization_id: Ecto.UUID.generate(),
                   entitlement_digest: "forged",
                   record_hash: "forged"
                 },
                 authorize?: false
               )
    end

    test "cannot be recorded on a closed campaign", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)
      {:ok, _} = close(campaign, "closer@example.test")
      row = rows(campaign)["alice@example.test"]

      assert {:error, error} = AccessReview.decide(row.id, "dave@example.test", :revoke, nil)
      assert Exception.message(error) =~ "closed"
    end

    test "a changed mind is a new decision; the earlier one stays", %{org: org} do
      campaign = open!(org, [S.App])
      row = rows(campaign)["alice@example.test"]
      bob = rows(campaign)["bob@example.test"]

      {:ok, first} = AccessReview.decide(row.id, "dave@example.test", :keep, nil)
      {:ok, second} = AccessReview.decide(row.id, "dave@example.test", :revoke, "changed my mind")
      {:ok, _} = AccessReview.decide(bob.id, "dave@example.test", :keep, nil)

      assert length(decisions(campaign)) == 3
      assert first.id != second.id

      assert {:ok, %{campaign: closed}} = close(campaign, "closer@example.test")
      assert %{"keep" => 1, "revoke" => 1, "decisions" => 3, "rows" => 2} = closed.close_summary
    end
  end

  describe "append-only" do
    test "the resources expose no way to change or remove a decision" do
      for resource <- [AccessReviewDecision, AccessReviewRow] do
        types = resource |> Ash.Resource.Info.actions() |> Enum.map(& &1.type)
        refute :update in types
        refute :destroy in types
      end
    end

    test "the database refuses to change or remove a decision", %{org: org} do
      campaign = open!(org, [S.App])
      row = rows(campaign)["alice@example.test"]
      {:ok, decision} = AccessReview.decide(row.id, "dave@example.test", :revoke, nil)
      id = Ecto.UUID.dump!(decision.id)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        TestRepo.query!(
          "UPDATE ash_compliance_access_review_decisions SET decision = 'keep' WHERE id = $1",
          [id]
        )
      end
    end
  end

  describe "closing" do
    test "with undecided rows is refused", %{org: org} do
      campaign = open!(org, [S.App, S.Legacy])
      row = rows(campaign)["alice@example.test"]
      {:ok, _} = AccessReview.decide(row.id, "dave@example.test", :keep, nil)

      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "2 row(s) have no decision"
      assert reload(campaign).status == :open
      assert evidence(org, "CC6.2") == []
    end

    test "with no decisions at all is refused", %{org: org} do
      campaign = open!(org, [S.App])
      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "no decision"
    end

    test "a complete, decided, intact campaign closes and writes evidence", %{org: org} do
      campaign = open!(org, [S.App, S.Legacy])
      decide_all!(campaign)

      assert {:ok, %{campaign: closed, artifacts: artifacts}} =
               close(campaign, "closer@example.test")

      assert closed.status == :closed
      assert closed.closed_by == "closer@example.test"
      assert %DateTime{} = closed.closed_at

      assert %{"rows" => 3, "keep" => 3, "revoke" => 0, "seal_digest" => digest} =
               closed.close_summary

      assert byte_size(digest) == 64

      assert artifacts |> Enum.map(& &1.control_id) |> Enum.sort() == ["CC6.2", "CC6.3"]

      for control <- ["CC6.2", "CC6.3"] do
        assert [artifact] = evidence(org, control)
        assert artifact.collector == @collector
        assert artifact.subject_id == campaign.id
      end

      assert [%{outcome: :permitted}] = attempts(org, campaign.id)
    end

    test "closing twice is refused", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)
      {:ok, _} = close(campaign, "closer@example.test")

      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "already closed"
      assert length(evidence(org, "CC6.2")) == 1
    end

    test "by the person who opened it is refused and recorded", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)

      assert {:error, error} = close(campaign, "Owner@example.test")
      assert Exception.message(error) =~ "self_approval"
      assert reload(campaign).status == :open
      assert evidence(org, "CC6.2") == []
      assert [%{outcome: :refused, reason: "self_approval"}] = attempts(org, campaign.id)
    end

    test "through a delegation from the person who opened it is refused and recorded", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)

      assert {:error, error} =
               close(campaign, "closer@example.test", delegators: ["owner@example.test"])

      assert Exception.message(error) =~ "delegated_self_approval"
      assert reload(campaign).status == :open

      assert [%{outcome: :refused, reason: "delegated_self_approval"}] =
               attempts(org, campaign.id)
    end

    test "with the delegation chain not recorded is refused", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)

      assert {:error, _} = close(campaign, "closer@example.test", delegators: nil)
      assert reload(campaign).status == :open
    end

    test "after a decision was altered in the database is refused", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)
      [decision | _] = decisions(campaign)

      TestRepo.query!("SET session_replication_role = replica")

      TestRepo.query!(
        "UPDATE ash_compliance_access_review_decisions SET decision = 'revoke' WHERE id = $1",
        [Ecto.UUID.dump!(decision.id)]
      )

      TestRepo.query!("SET session_replication_role = DEFAULT")

      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "fail their seal"
      assert reload(campaign).status == :open
      assert evidence(org, "CC6.2") == []
    end

    test "after a decision's reviewer was rewritten is refused", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)
      [decision | _] = decisions(campaign)

      TestRepo.query!("SET session_replication_role = replica")

      TestRepo.query!(
        "UPDATE ash_compliance_access_review_decisions SET reviewer_id = 'someone-else' WHERE id = $1",
        [Ecto.UUID.dump!(decision.id)]
      )

      TestRepo.query!("SET session_replication_role = DEFAULT")

      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "fail their seal"
    end

    test "after a decision was deleted leaves a row undecided and is refused", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)
      [decision | _] = decisions(campaign)

      TestRepo.query!("SET session_replication_role = replica")

      TestRepo.query!("DELETE FROM ash_compliance_access_review_decisions WHERE id = $1", [
        Ecto.UUID.dump!(decision.id)
      ])

      TestRepo.query!("SET session_replication_role = DEFAULT")

      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "no decision"
    end

    test "after a row's entitlements changed is refused", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)
      row = rows(campaign)["alice@example.test"]

      TestRepo.query!(
        "UPDATE ash_compliance_access_review_rows SET entitlements = '{\"app\": []}'::jsonb WHERE id = $1",
        [Ecto.UUID.dump!(row.id)]
      )

      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "changed after they were created"
      assert evidence(org, "CC6.2") == []
    end

    test "after a row's digest was rewritten to match is refused", %{org: org} do
      campaign = open!(org, [S.App])
      decide_all!(campaign)
      row = rows(campaign)["alice@example.test"]
      forged = Merge.digest(%{"app" => []})

      TestRepo.query!(
        "UPDATE ash_compliance_access_review_rows SET entitlements = '{\"app\": []}'::jsonb, entitlement_digest = $2 WHERE id = $1",
        [Ecto.UUID.dump!(row.id), forged]
      )

      assert {:error, error} = close(campaign, "closer@example.test")
      assert Exception.message(error) =~ "do not match the row they were made on"
    end

    test "without a collector the campaign closes but the missing evidence is reported", %{
      org: org
    } do
      campaign = open!(org, [S.App])
      decide_all!(campaign)

      assert {:error, {:evidence_not_recorded, closed, :no_producer}} =
               AccessReview.close(campaign.id, "closer@example.test", collector: nil)

      assert closed.status == :closed
      assert evidence(org, "CC6.2") == []
    end
  end

  test "campaigns can be listed for an organization", %{org: org} do
    campaign = open!(org, [S.App])
    assert [%{id: id}] = Domain.access_review_campaigns_for_organization!(org, authorize?: false)
    assert id == campaign.id
    assert AccessReviewCampaign |> Ash.Resource.Info.action(:close) |> Map.get(:type) == :update
  end
end
