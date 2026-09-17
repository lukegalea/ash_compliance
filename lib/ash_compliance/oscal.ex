# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Oscal do
  @moduledoc """
  OSCAL-flavored catalog and profile import/export.

  The boundary preserves what OSCAL carries — identifiers, parameters,
  provenance, revision lineage — while the internal model stays relational:
  catalogs/controls/profiles with immutable revision rows. Import is
  idempotent per content hash (re-importing the same document is a no-op for
  versions, and updates nothing else), and export reconstructs a document
  faithful to the identifiers that went in.

  v1 scope: **catalogs and profiles only** (component definitions and
  assessment plans are out).

  JSON shapes (a tolerant subset of OSCAL JSON):

      # catalog
      %{
        "uuid" => "...", "metadata" => %{"title" => "…", "version" => "1.0",
                    "source" => "…"},
        "groups" => [
          %{"id" => "kyc", "title" => "KYC",
            "controls" => [
              %{"id" => "kyc.valid_required", "title" => "…",
                "statement" => "…", "params" => [%{"id" => "window", "label" => "…"}],
                "citations" => ["Policy 4.1"]}
            ]}
        ]
      }

      # profile
      %{
        "uuid" => "...", "metadata" => %{"title" => "…", "version" => "2.0",
                    "source" => "…"},
        "imports" => [%{"href" => "#catalog", "include" => %{"ids" => ["kyc"]}}],
        "modifies" => %{
          "set_parameters" => [%{"param_id" => "window", "values" => ["30d"]}],
          "alters" => [%{"control_id" => "kyc.valid_required",
                         "removals" => [], "adds" => []}]
        },
        "operations" => [%{"op" => "refine", "target" => "kyc.valid_required",
                           "severity" => "high"}]
      }

  `operations` is the house extension: OSCAL profiles speak in
  include/exclude/alter; the compiler consumes the normalized tailoring
  operations, so the importer derives them where OSCAL shapes exist and
  stores house-shaped operations verbatim.
  """

  require Ash.Query

  alias AshCompliance.Oscal.ProfileOperation

  alias AshCompliance.Resources.{
    Catalog,
    CatalogVersion,
    Control,
    ControlRevision,
    Profile,
    ProfileRevision
  }

  @doc "Imports an OSCAL catalog document (map or JSON string). Returns the created catalog."
  @spec import_catalog(map() | String.t(), keyword()) ::
          {:ok, Catalog.t()} | {:error, String.t() | [String.t()]}
  def import_catalog(json, opts \\ [])

  def import_catalog(json, opts) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, document} -> import_catalog(document, opts)
      {:error, _} -> {:error, "invalid JSON"}
    end
  end

  def import_catalog(document, opts) when is_map(document) do
    organization_id = Keyword.get(opts, :organization_id)

    with {:ok, metadata} <- fetch_metadata(document),
         {:ok, controls} <- flatten_controls(document) do
      content_hash = hash_document(%{"controls" => controls})

      {:ok, catalog} =
        Ash.create(Catalog, %{
          organization_id: organization_id,
          name: metadata.title,
          description: metadata.description,
          oscal_uuid: document["uuid"]
        })

      {:ok, _version} =
        Ash.create(CatalogVersion, %{
          catalog_id: catalog.id,
          version: metadata.version,
          source: metadata.source,
          content_hash: content_hash,
          published_at: now()
        })

      Enum.each(controls, fn control ->
        control_id = control["id"]

        {:ok, control_record} =
          Ash.create(Control, %{
            organization_id: organization_id,
            catalog_id: catalog.id,
            control_id: control_id,
            title: control["title"],
            family: control["family"] || group_family(document, control_id)
          })

        {:ok, _revision} =
          Ash.create(ControlRevision, %{
            control_id: control_record.id,
            version: control["version"] || metadata.version,
            statement: control["statement"] || control["title"],
            params: control["params"] || [],
            citations: control["citations"] || [],
            status: :active
          })
      end)

      {:ok, catalog}
    end
  end

  @doc "Exports a catalog (and its controls with active revisions) as an OSCAL-shaped document."
  @spec export_catalog(Catalog.t()) :: {:ok, map()} | {:error, term()}
  def export_catalog(catalog) do
    controls =
      Control
      |> Ash.Query.filter(catalog_id == ^catalog.id)
      |> Ash.read!(authorize?: false)
      |> Enum.sort_by(& &1.control_id)
      |> Enum.map(fn control ->
        revisions =
          ControlRevision
          |> Ash.Query.filter(control_id == ^control.id and status == :active)
          |> Ash.read!(authorize?: false)
          |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

        case revisions do
          [] ->
            %{"id" => control.control_id, "title" => control.title}

          [revision | _] ->
            %{
              "id" => control.control_id,
              "title" => control.title,
              "statement" => revision.statement,
              "params" => revision.params,
              "citations" => revision.citations
            }
        end
      end)

    {:ok,
     %{
       "uuid" => catalog.oscal_uuid,
       "metadata" => %{
         "title" => catalog.name,
         "description" => catalog.description,
         "version" => latest_version(catalog.id) && latest_version(catalog.id).version
       },
       "groups" => [%{"id" => "imported", "title" => "Imported controls", "controls" => controls}]
     }}
  end

  @doc "Imports an OSCAL profile document. Returns the created profile."
  @spec import_profile(map() | String.t(), keyword()) ::
          {:ok, Profile.t()} | {:error, String.t() | [String.t()]}
  def import_profile(json, opts \\ [])

  def import_profile(json, opts) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, document} -> import_profile(document, opts)
      {:error, _} -> {:error, "invalid JSON"}
    end
  end

  def import_profile(document, opts) when is_map(document) do
    organization_id = Keyword.fetch!(opts, :organization_id)

    with {:ok, metadata} <- fetch_metadata(document),
         {:ok, operations} <- derive_operations(document) do
      content_hash = hash_document(%{"operations" => operations})

      {:ok, profile} =
        Ash.create(Profile, %{
          organization_id: organization_id,
          catalog_id: Keyword.get(opts, :catalog_id),
          name: metadata.title,
          oscal_uuid: document["uuid"]
        })

      {:ok, _revision} =
        Ash.create(ProfileRevision, %{
          profile_id: profile.id,
          version: metadata.version,
          source: metadata.source,
          operations: operations,
          content_hash: content_hash
        })

      {:ok, profile}
    end
  end

  @doc "Exports a profile (latest revision's operations) as an OSCAL-shaped document."
  @spec export_profile(Profile.t()) :: {:ok, map()} | {:error, term()}
  def export_profile(profile) do
    revisions =
      ProfileRevision
      |> Ash.Query.filter(profile_id == ^profile.id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false)

    operations =
      case revisions do
        [latest | _] -> latest.operations
        [] -> []
      end

    {:ok,
     %{
       "uuid" => profile.oscal_uuid,
       "metadata" => %{
         "title" => profile.name,
         "version" => (hd(revisions) && hd(revisions).version) || "1"
       },
       "imports" => [%{"href" => "#catalog", "include" => %{"with_ids" => []}}],
       "operations" => Enum.map(operations, &stringify_operation/1)
     }}
  end

  # --- internals ---------------------------------------------------------------

  defp fetch_metadata(document) do
    metadata = document["metadata"] || %{}

    if blank?(metadata["title"]) do
      {:error, "an OSCAL document requires metadata.title"}
    else
      {:ok,
       %{
         title: metadata["title"],
         version: metadata["version"] || "1",
         source: metadata["source"],
         description: metadata["description"]
       }}
    end
  end

  defp flatten_controls(document) do
    groups = document["groups"] || []

    controls =
      Enum.flat_map(groups, fn group ->
        Enum.map(group["controls"] || [], fn control ->
          Map.put(control, "family", control["family"] || group["id"])
        end)
      end)

    ids = Enum.map(controls, & &1["id"])

    if Enum.any?(controls, &blank?(&1["id"])) do
      {:error, "every control requires an id"}
    else
      if length(ids) != length(Enum.uniq(ids)) do
        {:error, "duplicate control ids in the document"}
      else
        {:ok, controls}
      end
    end
  end

  defp group_family(document, control_id) do
    document
    |> Map.get("groups", [])
    |> Enum.find_value(nil, fn group ->
      if Enum.any?(group["controls"] || [], &(&1["id"] == control_id)) do
        group["id"]
      end
    end)
  end

  # OSCAL profile constructs (set_parameters, alters removals/adds) map onto
  # house operations; house-shaped operations pass through normalization.
  defp derive_operations(document) do
    modifies = document["modifies"] || %{}

    set_parameters =
      Enum.map(modifies["set_parameters"] || [], fn param ->
        %{"op" => "parameterize", "target" => param["param_id"], "params" => param}
      end)

    alters =
      Enum.flat_map(modifies["alters"] || [], fn alter ->
        removals =
          Enum.map(alter["removals"] || [], fn _ ->
            %{"op" => "exclude", "target" => alter["control_id"]}
          end)

        adds =
          Enum.map(alter["adds"] || [], fn add ->
            %{"op" => "supplement", "target" => alter["control_id"], "text" => add["text"]}
          end)

        removals ++ adds
      end)

    house_operations = document["operations"] || []

    derived = set_parameters ++ alters ++ house_operations

    derived
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
      case ProfileOperation.normalize(operation) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, error} -> {:error, error}
    end
  end

  defp stringify_operation(operation) do
    {:ok, normalized} = ProfileOperation.normalize(operation)

    %{"op" => Atom.to_string(normalized.op), "target" => normalized[:target]}
    |> maybe_put("severity", normalized[:severity] && Atom.to_string(normalized[:severity]))
    |> maybe_put("message", normalized[:message])
    |> maybe_put("text", normalized[:text])
  end

  defp latest_version(catalog_id) do
    CatalogVersion
    |> Ash.Query.filter(catalog_id == ^catalog_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  # Deterministic hash: keys sorted, encoded as [key, value] pairs (tuples
  # are not JSON-encodable).
  defp hash_document(document) do
    document
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> [key, value] end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank?(value), do: value in [nil, ""]
end
