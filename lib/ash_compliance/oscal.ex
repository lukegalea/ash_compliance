# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Oscal do
  @moduledoc """
  OSCAL-flavored catalog and profile import/export.

  The boundary preserves what OSCAL carries — identifiers, parameters,
  provenance, revision lineage — while the internal model stays relational:
  catalogs/controls/profiles with immutable revision rows. Imports are
  identity- and content-aware: re-importing the same document is a no-op;
  a changed document opens a new version and withdraws the predecessors
  it supersedes (see `import_catalog/2`).

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

  alias AshCompliance.Oscal.ProfileOperation

  alias AshCompliance.Domain
  # Aliased for the @spec types only; calls go through the domain interfaces.
  alias AshCompliance.Resources.{Catalog, Profile}

  # Host-facing entry points default to trusted machinery — no actor, no
  # policy evaluation — because their callers are mix tasks and host consoles.
  # A host that runs imports/exports inside a policy perimeter threads its own
  # `actor:`/`authorize?:` through `opts`; everything below passes them on.
  defp call_opts(opts) do
    [
      actor: Keyword.get(opts, :actor),
      authorize?: Keyword.get(opts, :authorize?, false)
    ]
  end

  @doc """
  Imports an OSCAL catalog document (map or JSON string). Returns the
  created catalog.

  ## Import discipline (re-import semantics)

  Imports are identity-aware: a document whose `(organization_id, name)`
  matches an existing catalog is a **re-import**, resolved by content:

    * **Same content as the catalog's latest version** → **no-op**: the
      existing catalog is returned unchanged, nothing is written. This is
      the idempotence this module has always claimed.
    * **Different content** → a **new version on the same catalog row**:
      a new `CatalogVersion` is pinned, and the controls are ruled
      **per-control** (see `import_controls/6`): unchanged controls are
      skipped, changed controls get their predecessors **withdrawn at the
      import instant** (a period-split write — the predecessor's active
      history stays readable as-of before the instant) and a new active
      revision at that same instant, and changed content under a version
      string the control already uses is refused. The multi-active drift
      — repeated imports leaving several active revisions per control —
      is killed at its source. A catalog version string that already
      exists with different content is likewise refused: a re-import must
      carry a new `metadata.version`.
    * **No matching catalog** → fresh import, as always.

  The `:published_at` option declares the **publication instant** for the
  whole import (a historical import lands at its true publication time):
  it pins the catalog version's period lower bound and the control
  revisions' creation instants, and the predecessor withdrawal splits at
  the same instant, so the history stays coherent. Absent, everything
  lands at wall-now.

  Withdraw-then-create is sequential per control and the import is not
  wrapped in one transaction (pre-existing behavior): a failure partway
  leaves the controls imported so far — with predecessors correctly
  withdrawn at the same instant, so no multi-active state is possible
  even mid-import.
  """
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
    instant = Keyword.get(opts, :published_at) || now()
    opts = call_opts(opts)

    with {:ok, metadata} <- fetch_metadata(document),
         {:ok, controls} <- flatten_controls(document) do
      content_hash = hash_document(%{"controls" => controls})

      case Domain.catalog_by_organization_and_name(organization_id, metadata.title, opts) do
        {:ok, nil} ->
          with {:ok, catalog} <-
                 Domain.create_catalog(
                   %{
                     organization_id: organization_id,
                     name: metadata.title,
                     description: metadata.description,
                     oscal_uuid: document["uuid"]
                   },
                   opts
                 ),
               {:ok, _version} <-
                 Domain.create_catalog_version(
                   %{
                     catalog_id: catalog.id,
                     version: metadata.version,
                     source: metadata.source,
                     content_hash: content_hash,
                     published_at: instant
                   },
                   opts
                 ),
               :ok <-
                 import_controls(organization_id, catalog.id, controls, metadata, instant, opts) do
            {:ok, catalog}
          end

        {:ok, catalog} ->
          reimport_catalog(catalog, metadata, controls, content_hash, instant, opts)

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # The re-import path: new version on the same catalog row, predecessors
  # withdrawn at the import instant. Same content is a no-op (ruled before
  # this runs).
  defp reimport_catalog(catalog, metadata, controls, content_hash, instant, opts) do
    latest = Domain.latest_catalog_version!(catalog.id, opts)

    if latest && latest.content_hash == content_hash do
      # Same-content re-import: idempotent no-op.
      {:ok, catalog}
    else
      with {:ok, _version} <-
             create_version_on_conflict(catalog.id, metadata, content_hash, instant, opts),
           :ok <-
             import_controls(
               catalog.organization_id,
               catalog.id,
               controls,
               metadata,
               instant,
               opts
             ) do
        {:ok, catalog}
      end
    end
  end

  defp create_version_on_conflict(catalog_id, metadata, content_hash, instant, opts) do
    case Domain.create_catalog_version(
           %{
             catalog_id: catalog_id,
             version: metadata.version,
             source: metadata.source,
             content_hash: content_hash,
             published_at: instant
           },
           opts
         ) do
      {:ok, version} ->
        {:ok, version}

      {:error, %Ash.Error.Invalid{} = error} ->
        if Enum.any?(error.errors, &(&1.message =~ "has already been taken")) do
          {:error,
           "catalog version #{inspect(metadata.version)} already exists for this catalog " <>
             "with different content — a re-import must carry a new metadata.version"}
        else
          {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Imports (or re-imports) the document's controls onto the catalog, one
  # ruling per control (the import discipline):
  #
  #   * Unchanged content → skipped: no withdrawal, no new period. A
  #     re-import that changed one control does not churn the others.
  #   * Changed content under a version string the control already uses →
  #     refused, before anything is written for that control: a re-import
  #     must carry a new control version.
  #   * Changed content under a new version string → the predecessors are
  #     withdrawn at the import instant (every active, draining any
  #     pre-discipline multi-active drift) and the new active revision is
  #     created at that same instant — adjacent periods, no multi-active
  #     state.
  #   * New control → created directly active, as always.
  #
  # Because the refusals pre-check before any withdrawal, a control can
  # never be left withdrawn-with-no-successor.
  defp import_controls(organization_id, catalog_id, controls, metadata, instant, opts) do
    existing_controls =
      if catalog_id do
        Domain.controls_for_catalog!(catalog_id, opts)
      else
        []
      end

    Enum.reduce_while(controls, :ok, fn control, :ok ->
      control_id = control["id"]
      existing = Enum.find(existing_controls, &(&1.control_id == control_id))

      new_content = %{
        version: control["version"] || metadata.version,
        statement: control["statement"] || control["title"],
        params: control["params"] || [],
        citations: control["citations"] || []
      }

      ruling =
        case existing do
          nil ->
            :create

          found ->
            rule_control(found, new_content, instant, opts)
        end

      case ruling do
        :skip ->
          {:cont, :ok}

        {:refuse, message} ->
          {:halt, {:error, message}}

        :create ->
          {:ok, control_record} =
            case existing do
              nil ->
                Domain.create_control(
                  %{
                    organization_id: organization_id,
                    catalog_id: catalog_id,
                    control_id: control_id,
                    title: control["title"],
                    # flatten_controls resolved each control's family already.
                    family: control["family"]
                  },
                  opts
                )

              found ->
                {:ok, found}
            end

          case create_active_revision(control_record, new_content, instant, opts) do
            {:ok, _revision} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
  end

  # The per-control ruling for a re-import (see import_controls/6).
  defp rule_control(control, new_content, instant, opts) do
    history = Domain.control_revisions_for_control!(control.id, opts)

    content_matches? = fn revision ->
      revision.statement == new_content.statement and
        revision.params == new_content.params and
        revision.citations == new_content.citations
    end

    cond do
      # Unchanged content: this control is a no-op (the catalog version
      # still records the re-publication).
      Enum.any?(history, content_matches?) ->
        :skip

      # Changed content under a used version string: refuse before any
      # withdrawal — never leave a control withdrawn with no successor.
      Enum.any?(history, &(&1.version == new_content.version)) ->
        {:refuse,
         "control #{inspect(control.control_id)} version #{inspect(new_content.version)} " <>
           "already exists with different content — a re-import must carry a new control version"}

      # Changed content under a new version string: withdraw every active
      # predecessor at the instant (draining the multi-active drift) and
      # open the successor there.
      true ->
        withdraw_predecessors(control, instant, opts)
        :create
    end
  end

  defp create_active_revision(control_record, new_content, instant, opts) do
    Domain.create_control_revision(
      %{
        control_id: control_record.id,
        version: new_content.version,
        statement: new_content.statement,
        params: new_content.params,
        citations: new_content.citations,
        status: :active
      },
      Keyword.put(opts, :as_of, instant)
    )
  end

  # Every ACTIVE revision of the control is withdrawn at the instant —
  # not just the newest: a catalog re-imported over the old multi-active
  # drift drains it in one pass.
  defp withdraw_predecessors(control, instant, opts) do
    control.id
    |> Domain.active_control_revisions!(opts)
    |> Enum.each(fn predecessor ->
      Domain.withdraw_control_revision!(predecessor, Keyword.put(opts, :as_of, instant))
    end)
  end

  @doc """
  Exports a catalog (and its controls with active revisions) as an
  OSCAL-shaped document.

  Accepts `actor:`/`authorize?:` like the import functions; defaults to the
  trusted-machinery bypass described at the top of this module.
  """
  @spec export_catalog(Catalog.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_catalog(catalog, opts \\ []) do
    opts = call_opts(opts)

    controls =
      catalog.id
      |> Domain.controls_for_catalog!(opts)
      |> Enum.sort_by(& &1.control_id)
      |> Enum.map(fn control ->
        revisions = Domain.active_control_revisions!(control.id, opts)

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

    # Non-raising: a catalog with no published version exports with a nil
    # version (not_found_error? is false on the action).
    {:ok, latest_version} = Domain.latest_catalog_version(catalog.id, opts)

    {:ok,
     %{
       "uuid" => catalog.oscal_uuid,
       "metadata" => %{
         "title" => catalog.name,
         "description" => catalog.description,
         "version" => latest_version && latest_version.version
       },
       "groups" => [%{"id" => "imported", "title" => "Imported controls", "controls" => controls}]
     }}
  end

  @doc """
  Imports an OSCAL profile document. Returns the created profile.

  Accepts `published_at:` like `import_catalog/2` — the profile revision's
  declared creation instant (a historical import lands at its true
  publication time). Profiles have no active/withdraw lifecycle, so there
  is no predecessor discipline: each import creates a new profile and
  revision, as always.
  """
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
    catalog_id = Keyword.get(opts, :catalog_id)
    instant = Keyword.get(opts, :published_at) || now()
    opts = call_opts(opts)

    with {:ok, metadata} <- fetch_metadata(document),
         {:ok, operations} <- derive_operations(document) do
      content_hash = hash_document(%{"operations" => operations})

      {:ok, profile} =
        Domain.create_profile(
          %{
            organization_id: organization_id,
            catalog_id: catalog_id,
            name: metadata.title,
            oscal_uuid: document["uuid"]
          },
          opts
        )

      {:ok, _revision} =
        Domain.create_profile_revision(
          %{
            profile_id: profile.id,
            version: metadata.version,
            source: metadata.source,
            operations: operations,
            content_hash: content_hash
          },
          Keyword.put(opts, :as_of, instant)
        )

      {:ok, profile}
    end
  end

  @doc """
  Exports a profile (latest revision's operations) as an OSCAL-shaped
  document.

  Accepts `actor:`/`authorize?:` like the import functions; defaults to the
  trusted-machinery bypass described at the top of this module.
  """
  @spec export_profile(Profile.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_profile(profile, opts \\ []) do
    opts = call_opts(opts)

    revisions = Domain.profile_revisions_for_profile!(profile.id, opts)

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
