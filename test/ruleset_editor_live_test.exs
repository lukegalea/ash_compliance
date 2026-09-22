# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.RulesetEditorLiveTest do
  @moduledoc """
  The ruleset editor, driven without a browser.

  Every lifecycle assertion goes through the hidden toolbar forms rather than
  client events, which is the whole reason those forms exist: an editor whose
  only path to the database runs through JavaScript is an editor with no
  server-side tests, and the parts most worth testing — that saving
  serializes through the Ir encode path, that hydration shows what the
  engine decoded, that validate surfaces the verifier's diagnostics instead
  of swallowing them, that compile and activate end with an active bundle —
  are all server-side.

  What is deliberately *not* asserted here is anything about styling or the
  host's design system. The markup is plain semantic HTML with ids and
  data-* attributes; what those mean is the host's business.
  """

  use AshCompliance.WebConnCase, async: false

  alias AshCompliance.Resources.{PolicyBundle, RuleSetRevision}
  alias AshCompliance.Web.TestOrg

  @org TestOrg.organization_id()

  describe "opening the editor" do
    test "opens on a blank editor, scoped to the host's organization", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      assert has_element?(view, "#rule-set-editor[data-status='new']")
      assert has_element?(view, "#fact-editor input[name='facts[0][name]']")
      assert has_element?(view, "#rule-editor [data-rule-row='0']")

      # The organization scoping the host injected via its MFA.
      assert has_element?(
               view,
               "#ruleset-editor-live[data-organization-id='#{@org}']"
             )
    end

    test "the revision list shows statuses and the active bundle hash", %{conn: conn} do
      revision = create_revision()
      bundle = activate_and_compile(revision)

      {:ok, view, _html} = live(conn, "/editor")

      assert has_element?(view, "#rule-set-list [data-status='active']")
      assert has_element?(view, "#rule-set-list [data-revision-id='#{revision.id}']")
      assert has_element?(view, "#active-bundle[data-content-hash='#{bundle.content_hash}']")
    end
  end

  describe "hydration round trip" do
    test "editing an existing revision shows what the engine decoded, and saving drafts the next revision",
         %{
           conn: conn
         } do
      revision = create_revision()

      {:ok, view, _html} = live(conn, "/rule-sets/#{revision.id}/editor")

      # The hydrated form carries the decoded facts and rules as input values
      # — what the operator sees is what the engine will read back.
      assert has_element?(view, "#fact-editor input[value='status']")
      assert has_element?(view, "#fact-editor input[value='active, suspended']")
      assert has_element?(view, "#rule-editor input[value='kyc.valid_required']")
      assert has_element?(view, "#rule-editor input[value='customer']")
      assert has_element?(view, "#rule-set-editor[data-revision-id='#{revision.id}']")

      # Saving drafts a NEW revision: same content, bumped revision string,
      # the original untouched.
      render_submit(view, "draft", %{})

      reloaded = get_revision(revision.id)

      assert reloaded.revision == "1"

      drafts = drafts_for(@org)
      assert [saved] = Enum.filter(drafts, &(&1.id != revision.id))
      assert saved.name == reloaded.name
      assert saved.revision == "2"
      assert saved.status == :draft

      # Byte-identical serialization through state → Ir → encode: the round
      # trip is the editor's whole contract with the engine.
      assert saved.rules_json == reloaded.rules_json
      assert saved.content_hash == reloaded.content_hash
    end

    test "selecting a revision from the list hydrates the editor", %{conn: conn} do
      revision = create_revision()

      {:ok, view, _html} = live(conn, "/editor")

      view
      |> element("#rule-set-list [data-revision-id='#{revision.id}'] [data-action='select']")
      |> render_click()

      assert has_element?(view, "#rule-set-editor[data-revision-id='#{revision.id}']")
      assert has_element?(view, "#rule-editor input[value='kyc.valid_required']")
    end
  end

  describe "drafting" do
    test "serializes the submitted state through the Ir encode path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      name = "editor-draft-" <> AshCompliance.Support.unique()

      view
      |> element("#draft-form")
      |> render_submit(%{"state" => Jason.encode!(state_params(name))})

      assert [draft] = drafts_for(@org)
      assert draft.name == name
      assert draft.status == :draft
      assert draft.layer == :global_mandatory
      assert draft.combining == :deny_overrides

      # What got stored decodes, and it is the rule set that was submitted.
      assert {:ok, bundle} = AshRules.Ir.decode(draft.rules_json)
      assert [%{id: "kyc.reviewed"}] = bundle.rules
      assert Enum.map(bundle.fact_schema.facts, & &1.name) == [:reviewed, :status]

      assert %{content_hash: hash} = bundle
      assert draft.content_hash == hash
    end

    test "a rule set that does not verify is diagnosed inline and never stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      params =
        state_params("broken-" <> AshCompliance.Support.unique())
        |> put_in(["rules", Access.at(0), "requires", Access.at(0), "fact"], "ghost_fact")

      view
      |> element("#draft-form")
      |> render_submit(%{"state" => Jason.encode!(params)})

      # The verifier's diagnostics render — naming the unknown predicate —
      # and nothing partial is persisted.
      assert has_element?(view, "#ruleset-errors")
      assert render(view) =~ "ghost_fact"
      assert drafts_for(@org) == []
    end

    test "buffer edits flow into the saved revision", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      view
      |> element("[data-action='add_fact']")
      |> render_click()

      view
      |> element("#editor-buffer-form")
      |> render_change(%{
        "facts" => %{"1" => %{"name" => "balance"}},
        "_target" => ["facts", "1", "name"]
      })

      name = "buffer-edit-" <> AshCompliance.Support.unique()

      view
      |> element("#editor-buffer-form")
      |> render_change(%{"name" => name, "_target" => ["name"]})

      # The buffer's edits reached the editor state, so submit the form's own
      # rendered state — no override — and expect them in the saved revision.
      view
      |> element("#draft-form")
      |> render_submit(%{})

      assert [%{name: ^name} = draft] = drafts_for(@org)

      {:ok, bundle} = AshRules.Ir.decode(draft.rules_json)
      # The one typed fact is saved; the blank starter rows are skipped.
      assert Enum.map(bundle.fact_schema.facts, & &1.name) == [:balance]
      assert bundle.rules == []
    end
  end

  describe "the lifecycle" do
    test "draft → validate → approve → activate through the editor's handlers", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      name = "lifecycle-" <> AshCompliance.Support.unique()

      view
      |> element("#draft-form")
      |> render_submit(%{"state" => Jason.encode!(state_params(name))})

      assert [%{status: :draft} = draft] = drafts_for(@org)
      assert has_element?(view, "#rule-set-editor[data-revision-id='#{draft.id}']")

      render_submit(view, "validate", %{})
      assert %{status: :validated} = get_revision(draft.id)

      render_submit(view, "approve", %{})
      assert %{status: :approved} = get_revision(draft.id)

      render_submit(view, "activate", %{})
      assert %{status: :active} = get_revision(draft.id)

      assert has_element?(view, "#rule-set-list [data-status='active']")
    end

    test "a lifecycle refusal is surfaced, not swallowed", %{conn: conn} do
      revision =
        activate(create_revision(name: "refused-" <> AshCompliance.Support.unique()))

      {:ok, view, _html} = live(conn, "/rule-sets/#{revision.id}/editor")

      # An active revision cannot be approved: the domain refuses, and the
      # editor shows the refusal instead of swallowing it.
      render_submit(view, "approve", %{})

      assert has_element?(view, "#ruleset-errors")
      assert %{status: :active} = get_revision(revision.id)
    end
  end

  describe "validation diagnostics" do
    test "validate runs the engine's verifiers over the stored JSON", %{conn: conn} do
      revision = create_revision(name: "tampered-" <> AshCompliance.Support.unique())

      {:ok, view, _html} = live(conn, "/rule-sets/#{revision.id}/editor")

      # Storage-level tampering behind the editor's back, the same way the
      # lifecycle test corrupts a bundle: the stored JSON no longer decodes.
      Ecto.Adapters.SQL.query!(
        AshCompliance.TestRepo,
        "UPDATE ash_compliance_rule_set_revisions SET rules_json = '{broken' WHERE id = $1",
        [Ecto.UUID.dump!(revision.id)]
      )

      # The editor's buffer still points at the revision; validate fetches the
      # row fresh and runs the stored JSON through the verifiers.
      render_submit(view, "validate", %{})

      assert has_element?(view, "#ruleset-errors")
      assert %{status: :draft} = get_revision(revision.id)
    end
  end

  describe "compile and activate bundle" do
    test "compile resolves the layers and activate takes the bundle live", %{conn: conn} do
      revision = activate(create_revision(name: "bundle-" <> AshCompliance.Support.unique()))

      {:ok, view, _html} = live(conn, "/rule-sets/#{revision.id}/editor")

      view
      |> element("#compile-form")
      |> render_submit(%{"label" => "from the editor"})

      {:ok, compiled} = AshCompliance.Domain.active_policy_bundle(@org, authorize?: false)
      refute compiled
      assert [bundle] = compiled_bundles(@org)
      assert bundle.status == :compiled
      assert bundle.label == "from the editor"
      assert has_element?(view, "#ruleset-errors") == false

      view
      |> element("#activate-bundle-form")
      |> render_submit(%{})

      assert %{status: :active, content_hash: hash} = get_bundle(bundle.id)
      assert has_element?(view, "#active-bundle[data-content-hash='#{hash}']")

      {:ok, active} = AshCompliance.Domain.active_policy_bundle(@org, authorize?: false)
      assert active.id == bundle.id
    end
  end

  describe "organization scoping" do
    test "the route's organization_id overrides the host's MFA", %{conn: conn} do
      route_org = Ecto.UUID.generate()

      {:ok, view, _html} = live(conn, "/orgs/#{route_org}/editor")

      assert has_element?(
               view,
               "#ruleset-editor-live[data-organization-id='#{route_org}']"
             )

      name = "routed-org-" <> AshCompliance.Support.unique()

      view
      |> element("#draft-form")
      |> render_submit(%{"state" => Jason.encode!(state_params(name))})

      assert [%{organization_id: ^route_org}] = drafts_for(route_org)
      # The host's own org saw nothing.
      assert drafts_for(@org) == []
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp state_params(name) do
    %{
      "revision_id" => nil,
      "status" => "new",
      "name" => name,
      "revision" => "1",
      "layer" => "global_mandatory",
      "combining" => "deny_overrides",
      "source_module" => "",
      "facts" => [
        %{
          "name" => "status",
          "type" => "atom",
          "one_of" => "active, suspended",
          "missing" => "false",
          "description" => ""
        },
        %{
          "name" => "reviewed",
          "type" => "boolean",
          "one_of" => "",
          "missing" => "no_fact",
          "description" => ""
        }
      ],
      "rules" => [
        %{
          "name" => "active customers carry a recorded review",
          "id" => "kyc.reviewed",
          "severity" => "high",
          "outcome" => "noncompliant",
          "gap" => "kyc.review",
          "message" => "customer %{customer} is not reviewed",
          "requires" => [%{"subject" => "customer", "fact" => "status", "value" => "active"}],
          "fails" => [%{"subject" => "customer", "fact" => "reviewed", "value" => "true"}]
        }
      ]
    }
  end

  defp create_revision(attrs \\ []) do
    AshCompliance.Test.Support.rule_set_revision(Keyword.merge([organization_id: @org], attrs))
  end

  defp activate(revision) do
    revision
    |> AshCompliance.Domain.validate_rule_set_revision!(authorize?: false)
    |> AshCompliance.Domain.approve_rule_set_revision!(authorize?: false)
    |> AshCompliance.Domain.activate_rule_set_revision!(authorize?: false)
  end

  defp activate_and_compile(revision) do
    activate(revision)

    AshCompliance.Domain.compile_policy_bundle!(
      %{organization_id: @org, label: "list test"},
      authorize?: false
    )
    |> AshCompliance.Domain.activate_policy_bundle!(authorize?: false)
  end

  defp get_revision(id),
    do: AshCompliance.Domain.get_rule_set_revision_by_id!(id, authorize?: false)

  defp get_bundle(id), do: AshCompliance.Domain.get_policy_bundle_by_id!(id, authorize?: false)

  defp drafts_for(organization_id) do
    RuleSetRevision
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.do_filter(organization_id: organization_id, status: :draft)
    |> Ash.read!(authorize?: false)
  end

  defp compiled_bundles(organization_id) do
    PolicyBundle
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.do_filter(organization_id: organization_id, status: :compiled)
    |> Ash.read!(authorize?: false)
  end
end
