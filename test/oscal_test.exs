# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OscalTest do
  @moduledoc """
  OSCAL import/export round trips: identifiers, parameters, provenance and
  revision lineage survive the boundary.
  """

  use AshCompliance.DataCase, async: true

  require Ash.Query

  alias AshCompliance.Oscal
  alias AshCompliance.Resources.{Control, ControlRevision, ProfileRevision}

  @org Ecto.UUID.generate()

  @catalog_document %{
    "uuid" => "cat-uuid-1",
    "metadata" => %{
      "title" => "KYC Baseline",
      "version" => "1.2",
      "source" => "imported from policy-office",
      "description" => "The baseline"
    },
    "groups" => [
      %{
        "id" => "kyc",
        "title" => "Know Your Customer",
        "controls" => [
          %{
            "id" => "kyc.valid_required",
            "title" => "Valid KYC",
            "statement" => "Active regulated customers must hold valid KYC",
            "params" => [%{"id" => "window", "label" => "Review window"}],
            "citations" => ["Policy 4.1"]
          },
          %{"id" => "kyc.review", "title" => "Recorded review"}
        ]
      }
    ]
  }

  @profile_document %{
    "uuid" => "profile-uuid-1",
    "metadata" => %{"title" => "Tenant tailoring", "version" => "2.0"},
    "imports" => [%{"href" => "#catalog", "include" => %{"ids" => ["kyc"]}}],
    "modifies" => %{
      "set_parameters" => [%{"param_id" => "window", "values" => ["30d"]}],
      "alters" => [
        %{"control_id" => "kyc.review", "removals" => [], "adds" => [%{"text" => "guidance"}]}
      ]
    }
  }

  describe "catalog import/export" do
    test "import creates the catalog, a version, controls and active revisions" do
      {:ok, catalog} = Oscal.import_catalog(@catalog_document, organization_id: @org)

      assert catalog.name == "KYC Baseline"
      assert catalog.oscal_uuid == "cat-uuid-1"

      controls =
        Control
        |> Ash.Query.filter(catalog_id == ^catalog.id)
        |> Ash.read!(authorize?: false)
        |> Enum.sort_by(& &1.control_id)

      assert Enum.map(controls, & &1.control_id) == ["kyc.review", "kyc.valid_required"]

      valid_required = Enum.find(controls, &(&1.control_id == "kyc.valid_required"))

      revisions =
        ControlRevision
        |> Ash.Query.filter(control_id == ^valid_required.id)
        |> Ash.read!(authorize?: false)

      assert [%{status: :active, params: [%{"id" => "window"}], citations: ["Policy 4.1"]}] =
               revisions
    end

    test "export reconstructs identifiers, statement, params and citations" do
      {:ok, catalog} = Oscal.import_catalog(@catalog_document, organization_id: @org)
      {:ok, exported} = Oscal.export_catalog(catalog)

      assert exported["uuid"] == "cat-uuid-1"
      assert exported["metadata"]["title"] == "KYC Baseline"

      control_ids =
        exported["groups"]
        |> Enum.flat_map(& &1["controls"])
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert control_ids == ["kyc.review", "kyc.valid_required"]

      kyc =
        exported["groups"]
        |> Enum.flat_map(& &1["controls"])
        |> Enum.find(&(&1["id"] == "kyc.valid_required"))

      assert kyc["statement"] =~ "valid KYC"
      assert [%{"id" => "window"}] = kyc["params"]
      assert kyc["citations"] == ["Policy 4.1"]
    end

    test "importing garbage is refused with a message" do
      assert {:error, message} = Oscal.import_catalog(%{"groups" => []})
      assert message =~ "metadata.title"
    end
  end

  describe "profile import/export" do
    test "import derives house operations from OSCAL modifies" do
      {:ok, profile} =
        Oscal.import_profile(@profile_document, organization_id: @org)

      assert profile.name == "Tenant tailoring"

      [revision] =
        ProfileRevision
        |> Ash.Query.filter(profile_id == ^profile.id)
        |> Ash.read!(authorize?: false)

      ops = revision.operations

      assert Enum.any?(ops, &(&1["op"] == "parameterize" and &1["target"] == "window"))
      assert Enum.any?(ops, &(&1["op"] == "supplement" and &1["target"] == "kyc.review"))
    end

    test "export emits the stored operations" do
      {:ok, profile} = Oscal.import_profile(@profile_document, organization_id: @org)
      {:ok, exported} = Oscal.export_profile(profile)

      assert exported["uuid"] == "profile-uuid-1"
      assert exported["metadata"]["title"] == "Tenant tailoring"

      ops = exported["operations"]
      assert Enum.any?(ops, &(&1["op"] == "parameterize"))
      assert Enum.any?(ops, &(&1["op"] == "supplement"))
    end

    test "approval-bearing operations are refused on import" do
      document = %{
        "metadata" => %{"title" => "sneaky", "version" => "1"},
        "operations" => [
          %{"op" => "waive", "target" => "kyc.valid_required"}
        ]
      }

      assert {:error, message} = Oscal.import_profile(document, organization_id: @org)
      assert message =~ "approval-bearing"
      assert message =~ "PolicyOverride"
    end
  end
end
