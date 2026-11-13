# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Retention do
  @moduledoc """
  Moves old evidence artifacts from the hot table to the host's evidence archive,
  verifying each move first, and purges the archive past a configured age.

  The archive is a resource the host builds with
  `use AshCompliance.Resources, {:evidence_archive, opts}`, named by the `:archive`
  option or by `config :ash_compliance, evidence_archive: MyApp.ArchivedEvidence`. The
  host calls `archive/1` and `purge/1` from its own scheduled job, with its own
  configuration and actor:

      AshCompliance.Ownership.Retention.archive(
        hot_days: 90,
        archive_run: MyApp.Audit.ArchiveRun,
        actor: MyApp.system_actor()
      )

  **The hot window.** An artifact collected more than `:hot_days` ago (at least
  90) moves to the archive, **unless it is the newest artifact of its organization,
  control and collector**. That one stays hot whatever its age, so the newest evidence a
  criterion rests on is always in the hot table: an annual control's single artifact is
  never moved for being a hundred days old.

  **A verified move.** Each move runs in one transaction: copy the rows, then compare
  the copy with the hot rows (the same count on both sides, every column equal, the same
  SHA-256 over their hashes in id order, and every stored `content` hashing to its
  `hash`). Only when all of that holds are the hot rows deleted, and only if the delete
  removes exactly the rows that were compared. A failed comparison rolls the transaction
  back, so nothing is copied and nothing deleted, and the step is `{:failed, run}` with
  the reason.

  **Retrying is safe.** The copy skips an artifact already in the archive
  (`ON CONFLICT DO NOTHING`) and the comparison then checks the row that is there. A
  move retried after its copy landed verifies and completes; one whose archived copy
  differs fails and deletes nothing.

  **Never purged before 400 days.** `purge/1` deletes archived artifacts only when
  `:purge_after_days` is given, and refuses a value under 400. The archive's guard
  trigger refuses to delete a younger row whatever the caller passes.

  **Reading.** Moving an artifact never changes what a read of evidence returns:
  `AshCompliance.Ownership.Evidence.for_control/3`, and through it the freshness sweep,
  reads the hot table and the archive together.

  ## Options

  For both functions:

    * `:archive` - the archive resource. Default: the `:evidence_archive` application
      setting. Without one, both return `{:error, :no_evidence_archive}`.
    * `:now` - the time the cutoff is counted back from. Default: now.
    * `:batch_size` - the most artifacts one call moves or purges. Default 10,000. A
      daily call catches up on a backlog over several days.
    * `:archive_run` - a run ledger resource with a `:record` create action that accepts
      `store`, `kind`, `status`, `row_count`, `digest`, `cutoff` and `reason` (the shape
      of `ash_events_chain`'s `{:archive_run, opts}`). Each step is recorded there, a
      verified move inside its own transaction. Without it, a step carries the attributes
      it would have recorded, as a map.
    * `:actor`, `:authorize?` - how the run ledger's `:record` action is called.
      Default: no actor, `authorize?: true`, so a host passes the actor its policies
      allow.

  `archive/1` also takes `:hot_days` (default and floor 90), and `purge/1` takes
  `:purge_after_days` (default `nil`, never; floor 400).

  ## Why this module writes SQL

  Neither the hot table nor the archive has an update or destroy action: evidence is
  never edited. A move is a set-based copy and delete between two tables in one
  transaction, checked by the archive's trigger. What retention records about itself
  goes through Ash, as the run ledger's `:record` action. The SQL is built from table and
  column names the resources fix at compile time; every value is a bound parameter.
  """

  alias AshCompliance.Resources, as: Macros
  alias AshCompliance.Resources.EvidenceArtifact

  @hot_floor_days 90
  @purge_floor_days 400
  @default_batch 10_000
  @store :evidence_artifacts

  @typedoc "What one call did."
  @type step :: :nothing | {:archived, term()} | {:purged, term()} | {:failed, term()}

  @doc "The fewest days an artifact stays hot. `:hot_days` below it is refused."
  @spec hot_floor_days() :: pos_integer()
  def hot_floor_days, do: @hot_floor_days

  @doc "The fewest days an artifact is kept at all. `:purge_after_days` below it is refused."
  @spec purge_floor_days() :: pos_integer()
  def purge_floor_days, do: @purge_floor_days

  @doc """
  The configured evidence archive, or `nil`.

      config :ash_compliance, evidence_archive: MyApp.Compliance.ArchivedEvidence
  """
  @spec configured_archive() :: module() | nil
  def configured_archive, do: Application.get_env(:ash_compliance, :evidence_archive)

  @doc """
  Moves one batch of artifacts past the hot window to the archive, verified.

  Returns `{:ok, step}`, `{:error, {:below_floor, :hot_days, floor}}` or
  `{:error, :no_evidence_archive}`.
  """
  @spec archive(keyword()) :: {:ok, step()} | {:error, term()}
  def archive(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    days = Keyword.get(opts, :hot_days) || @hot_floor_days
    batch = Keyword.get(opts, :batch_size) || @default_batch

    with {:ok, spec} <- spec(opts) do
      if days < @hot_floor_days do
        {:error, {:below_floor, :hot_days, @hot_floor_days}}
      else
        cutoff = DateTime.add(now, -days * 86_400, :second)

        case eligible(spec, cutoff, batch) do
          [] -> {:ok, :nothing}
          ids -> {:ok, move(spec, ids, cutoff, now, opts)}
        end
      end
    end
  end

  @doc """
  Deletes one batch of archived artifacts collected more than `:purge_after_days` ago.

  Returns `{:ok, :disabled}` when no age is given, `{:ok, step}`,
  `{:error, {:below_floor, :purge_after_days, floor}}` or
  `{:error, :no_evidence_archive}`.
  """
  @spec purge(keyword()) :: {:ok, :disabled | step()} | {:error, term()}
  def purge(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    batch = Keyword.get(opts, :batch_size) || @default_batch

    with {:ok, spec} <- spec(opts) do
      case Keyword.get(opts, :purge_after_days) do
        nil ->
          {:ok, :disabled}

        days when is_integer(days) and days >= @purge_floor_days ->
          {:ok, purge_batch(spec, DateTime.add(now, -days * 86_400, :second), batch, opts)}

        _ ->
          {:error, {:below_floor, :purge_after_days, @purge_floor_days}}
      end
    end
  end

  # --- archive ------------------------------------------------------------------

  # Older than the cutoff, and not the newest of its organization, control and collector.
  # sobelow_skip ["SQL.Query"]
  defp eligible(spec, cutoff, batch) do
    %{rows: rows} =
      spec.repo.query!(
        """
        SELECT e.id FROM #{spec.hot} e
        WHERE e.collected_at < $1
          AND EXISTS (
            SELECT 1 FROM #{spec.hot} n
            WHERE n.organization_id = e.organization_id
              AND n.control_id = e.control_id
              AND n.collector = e.collector
              AND (n.collected_at, n.id) > (e.collected_at, e.id))
        ORDER BY e.collected_at, e.id
        LIMIT $2
        """,
        [cutoff, batch]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  # sobelow_skip ["SQL.Query"]
  defp move(spec, ids, cutoff, now, opts) do
    count = length(ids)
    columns = Enum.join(Macros.columns(), ", ")

    result =
      spec.repo.transaction(fn ->
        spec.repo.query!(
          "INSERT INTO #{spec.archive_table} (#{columns}, archived_at) " <>
            "SELECT #{columns}, $2 FROM #{spec.hot} WHERE id = ANY($1) " <>
            "ON CONFLICT (id) DO NOTHING",
          [ids, now]
        )

        with {:ok, digest} <- verify_copy(spec, ids, count),
             :ok <- delete_hot(spec, ids, count) do
          record!(spec, opts, %{
            kind: :archive,
            status: :verified,
            row_count: count,
            digest: digest,
            cutoff: cutoff
          })
        else
          {:error, reason} -> spec.repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} ->
        {:archived, run}

      {:error, reason} ->
        fail(spec, opts, %{kind: :archive, row_count: count, cutoff: cutoff}, reason)
    end
  rescue
    # The database refused. The transaction rolled back: nothing copied, nothing deleted.
    error in Postgrex.Error ->
      fail(
        spec,
        opts,
        %{kind: :archive, row_count: length(ids), cutoff: cutoff},
        Exception.message(error)
      )
  end

  defp same_row do
    {archived, hot} =
      Macros.columns()
      |> Enum.map(&{"a.#{&1}", "h.#{&1}"})
      |> Enum.unzip()

    "(#{Enum.join(archived, ", ")}) IS NOT DISTINCT FROM (#{Enum.join(hot, ", ")})"
  end

  defp digest_of(alias_name) do
    "encode(sha256(convert_to(coalesce(string_agg(#{alias_name}.hash, '|' ORDER BY " <>
      "#{alias_name}.id), ''), 'UTF8')), 'hex')"
  end

  # sobelow_skip ["SQL.Query"]
  defp verify_copy(spec, ids, count) do
    %{rows: [[hot, archived, matching, bad_content, hot_digest, archive_digest]]} =
      spec.repo.query!(
        """
        SELECT
          (SELECT count(*) FROM #{spec.hot} h WHERE h.id = ANY($1)),
          (SELECT count(*) FROM #{spec.archive_table} a WHERE a.id = ANY($1)),
          (SELECT count(*) FROM #{spec.hot} h
             JOIN #{spec.archive_table} a ON a.id = h.id AND #{same_row()}
             WHERE h.id = ANY($1)),
          (SELECT count(*) FROM #{spec.archive_table} a
             WHERE a.id = ANY($1) AND a.content IS NOT NULL
               AND encode(sha256(a.content), 'hex') <> a.hash),
          (SELECT #{digest_of("h")} FROM #{spec.hot} h WHERE h.id = ANY($1)),
          (SELECT #{digest_of("a")} FROM #{spec.archive_table} a WHERE a.id = ANY($1))
        """,
        [ids]
      )

    cond do
      hot != count ->
        {:error, "hot artifacts changed under the move: #{hot} for #{count}"}

      archived != count ->
        {:error, "archive holds #{archived} artifacts for #{count}"}

      matching != count ->
        {:error, "#{count - matching} archived artifact(s) differ from the hot row"}

      bad_content > 0 ->
        {:error, "#{bad_content} archived artifact(s) do not hash to their hash"}

      hot_digest != archive_digest ->
        {:error, "digest mismatch"}

      true ->
        {:ok, hot_digest}
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp delete_hot(spec, ids, count) do
    %{num_rows: deleted} =
      spec.repo.query!(
        """
        DELETE FROM #{spec.hot} h
        WHERE h.id = ANY($1)
          AND EXISTS (SELECT 1 FROM #{spec.archive_table} a
                      WHERE a.id = h.id AND #{same_row()})
        """,
        [ids]
      )

    if deleted == count,
      do: :ok,
      else: {:error, "deleted #{deleted} artifacts for #{count} verified"}
  end

  # --- purge ----------------------------------------------------------------------

  # sobelow_skip ["SQL.Query"]
  defp purge_batch(spec, cutoff, batch, opts) do
    result =
      spec.repo.transaction(fn ->
        %{rows: [[digest]]} =
          spec.repo.query!(
            """
            SELECT #{digest_of("a")} FROM (
              SELECT id, hash FROM #{spec.archive_table}
              WHERE collected_at < $1 ORDER BY collected_at, id LIMIT $2) a
            """,
            [cutoff, batch]
          )

        %{num_rows: deleted} =
          spec.repo.query!(
            """
            DELETE FROM #{spec.archive_table}
            WHERE id IN (SELECT id FROM #{spec.archive_table}
                         WHERE collected_at < $1 ORDER BY collected_at, id LIMIT $2)
            """,
            [cutoff, batch]
          )

        if deleted > 0 do
          record!(spec, opts, %{
            kind: :purge,
            status: :verified,
            row_count: deleted,
            digest: digest,
            cutoff: cutoff
          })
        end
      end)

    case result do
      {:ok, nil} -> :nothing
      {:ok, run} -> {:purged, run}
    end
  rescue
    error in Postgrex.Error ->
      fail(spec, opts, %{kind: :purge, row_count: 0, cutoff: cutoff}, Exception.message(error))
  end

  # --- shared ---------------------------------------------------------------------

  defp spec(opts) do
    archive = Keyword.get_lazy(opts, :archive, &configured_archive/0)

    cond do
      is_nil(archive) ->
        {:error, :no_evidence_archive}

      not Macros.evidence_archive?(archive) ->
        raise ArgumentError,
              "#{inspect(archive)} is not built with " <>
                "`use AshCompliance.Resources, {:evidence_archive, opts}`"

      true ->
        hot_repo = AshPostgres.DataLayer.Info.repo(EvidenceArtifact, :mutate)
        archive_repo = AshPostgres.DataLayer.Info.repo(archive, :mutate)

        if hot_repo != archive_repo do
          raise ArgumentError,
                "#{inspect(archive)} uses #{inspect(archive_repo)}, but the hot evidence " <>
                  "table uses #{inspect(hot_repo)}: a move needs both in one transaction"
        end

        {:ok,
         %{
           repo: hot_repo,
           hot: table!(EvidenceArtifact),
           archive_table: table!(archive)
         }}
    end
  end

  defp table!(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)
    schema = AshPostgres.DataLayer.Info.schema(resource)

    for name <- [table, schema], not is_nil(name), not Macros.identifier?(name) do
      raise ArgumentError, "#{inspect(resource)}: #{inspect(name)} is not a plain SQL identifier"
    end

    if schema, do: "#{schema}.#{table}", else: table
  end

  defp record!(_spec, opts, attrs) do
    attrs = Map.put(attrs, :store, @store)

    case Keyword.get(opts, :archive_run) do
      nil ->
        attrs

      run ->
        run
        |> Ash.Changeset.for_create(:record, attrs,
          actor: Keyword.get(opts, :actor),
          authorize?: Keyword.get(opts, :authorize?, true)
        )
        |> Ash.create!()
    end
  end

  defp fail(spec, opts, attrs, reason) do
    {:failed,
     record!(spec, opts, Map.merge(attrs, %{status: :failed, reason: to_reason(reason)}))}
  end

  defp to_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp to_reason(reason), do: reason |> inspect() |> String.slice(0, 500)
end
