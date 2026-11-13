# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Evidence do
  @moduledoc """
  The writer for `AshCompliance.Resources.EvidenceArtifact`.

  An artifact written here is dated, carries the SHA-256 of its content, and
  names the producer that collected it (`collector`). The producer name is the
  same reference the control file's row carries, because the freshness
  evaluator only counts artifacts from the producer a row declares.

  Append-only: `EvidenceArtifact` has `create` and `read` actions and no
  update or destroy, so a correction is a new artifact. The content is stored on
  the row by default, because the freshness sweep counts an artifact as evidence
  only while `verify/1` still passes: the bytes are present and hash to the row's
  hash. Pass `store_content: false` to keep only the hash (the artifact then pins
  an identity but never counts as evidence). Stored bytes are also checked against
  the hash at create.

  Nothing is recorded when collection fails. A producer that errors, raises,
  or returns empty content leaves no artifact behind, so the control reads as
  stale or missing rather than as evidenced by something that never ran.
  """

  alias AshCompliance.Domain
  alias AshCompliance.Ownership.Retention
  alias AshCompliance.Resources.EvidenceArtifact

  # Clock skew tolerated before a collection time counts as future-dated.
  @skew_seconds 300

  @type producer :: (-> {:ok, binary()} | {:error, term()}) | {module(), atom(), list()}

  @doc """
  Records an artifact for `control_id`.

  Required options: `:producer` (the name that will be stored as the
  collector). Optional: `:media_type` (default `"application/octet-stream"`),
  `:method` (`:examine`, `:interview` or `:test`; default `:examine`),
  `:collected_at` (default now), `:now`, `:subject_type`, `:subject_id`,
  `:retention_class`, `:location`, `:actor`, `:authorize?`, `:store_content`
  (default `true`; keep the bytes on the row, without which the artifact is not evidence).

  Returns `{:error, reason}` for empty content, a blank producer, an invalid
  organization id, or a collection time later than now plus a small skew.
  """
  @spec record(String.t(), String.t(), binary(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def record(organization_id, control_id, content, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    collected_at = Keyword.get(opts, :collected_at, now)
    producer = Keyword.get(opts, :producer)

    with :ok <- check_content(content),
         :ok <- check_producer(producer),
         :ok <- check_control(control_id),
         :ok <- check_organization(organization_id),
         :ok <- check_time(collected_at, now) do
      attrs = %{
        organization_id: organization_id,
        control_id: control_id,
        subject_type: opts[:subject_type],
        subject_id: opts[:subject_id],
        hash: sha256(content),
        content: if(Keyword.get(opts, :store_content, true) == true, do: content),
        media_type: Keyword.get(opts, :media_type, "application/octet-stream"),
        collector: producer,
        method: Keyword.get(opts, :method, :examine),
        retention_class: opts[:retention_class],
        collected_at: collected_at,
        chain_of_custody: [
          %{
            "at" => DateTime.to_iso8601(collected_at),
            "actor" => producer,
            "action" => "collected",
            "location" => opts[:location]
          }
        ]
      }

      Domain.create_evidence_artifact(
        attrs,
        actor: opts[:actor],
        authorize?: Keyword.get(opts, :authorize?, false)
      )
    end
  end

  @doc """
  Runs `producer_fun` and records what it returns.

  The function (or `{module, function, args}`) returns `{:ok, content}` or
  `{:error, reason}`. An error, an exception, a throw, an exit, or empty
  content is returned as `{:error, {:producer_failed, reason}}` and nothing
  is written. The `:producer` option names the collector.
  """
  @spec collect(String.t(), String.t(), producer(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def collect(organization_id, control_id, producer_fun, opts) do
    case run_producer(producer_fun) do
      {:ok, content} -> record(organization_id, control_id, content, opts)
      {:error, reason} -> {:error, {:producer_failed, reason}}
    end
  end

  @doc """
  Every artifact recorded for `control_id` in `organization_id`, from the hot table and
  the evidence archive together, oldest first.

  An artifact moved by `AshCompliance.Ownership.Retention` is read from the archive, so
  moving one never changes what this returns. During a move an artifact can briefly be in
  both tables; it is returned once. Without an archive (no `:evidence_archive` setting
  and no `:archive` option) only the hot table is read.

  Options: `:archive` (the archive resource; default the `:evidence_archive` setting,
  `nil` for none), `:actor`, `:authorize?` (default `false`; evidence reads are trusted
  machinery, like the sweep).
  """
  @spec for_control(String.t(), String.t(), keyword()) :: {:ok, [struct()]} | {:error, term()}
  def for_control(organization_id, control_id, opts \\ []) do
    archive = Keyword.get_lazy(opts, :archive, &Retention.configured_archive/0)
    ash_opts = [actor: opts[:actor], authorize?: Keyword.get(opts, :authorize?, false)]

    with {:ok, hot} <- Domain.evidence_for_control(organization_id, control_id, ash_opts),
         {:ok, archived} <- archived(archive, organization_id, control_id, ash_opts) do
      {:ok,
       (hot ++ archived)
       |> Enum.uniq_by(& &1.id)
       |> Enum.sort(&collected_first?/2)}
    end
  end

  defp collected_first?(a, b) do
    case DateTime.compare(a.collected_at, b.collected_at) do
      :lt -> true
      :gt -> false
      :eq -> a.id <= b.id
    end
  end

  defp archived(nil, _organization_id, _control_id, _ash_opts), do: {:ok, []}

  defp archived(archive, organization_id, control_id, ash_opts) do
    archive
    |> Ash.Query.for_read(
      :for_control,
      %{organization_id: organization_id, control_id: control_id},
      ash_opts
    )
    |> Ash.read()
  end

  @doc """
  Where an artifact read by `for_control/3` lives: `:hot` for the package's own
  `EvidenceArtifact`, `:archive` for a row of the host's evidence archive.
  """
  @spec location(struct()) :: :hot | :archive
  def location(%EvidenceArtifact{}), do: :hot
  def location(_archived), do: :archive

  @doc """
  Re-checks an artifact's stored bytes against its hash.

  `:ok` only when the row holds non-empty bytes whose SHA-256 equals `hash`. An artifact
  with no stored bytes is `{:error, :no_content}`, and bytes that differ are
  `{:error, :hash_mismatch}`: neither is a pass.
  """
  @spec verify(struct()) :: :ok | {:error, :no_content | :hash_mismatch}
  def verify(%{content: content, hash: hash}) when is_binary(content) and content != "" do
    if sha256(content) == hash, do: :ok, else: {:error, :hash_mismatch}
  end

  def verify(_artifact), do: {:error, :no_content}

  @doc "Lower-case hex SHA-256 of `content`."
  @spec sha256(binary()) :: String.t()
  def sha256(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  @doc "True when `hash` has the shape of `sha256/1` output."
  @spec hash?(term()) :: boolean()
  def hash?(hash), do: is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

  @doc "Seconds of clock skew tolerated before a timestamp counts as future-dated."
  @spec skew_seconds() :: non_neg_integer()
  def skew_seconds, do: @skew_seconds

  defp run_producer(fun) when is_function(fun, 0), do: safely(fun)

  defp run_producer({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: safely(fn -> apply(module, function, args) end)

  defp run_producer(other), do: {:error, {:not_a_producer, other}}

  defp safely(fun) do
    case fun.() do
      {:ok, content} when is_binary(content) and content != "" -> {:ok, content}
      {:ok, _empty_or_invalid} -> {:error, :empty_content}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp check_content(content) when is_binary(content) and content != "", do: :ok
  defp check_content(_), do: {:error, :empty_content}

  defp check_producer(producer) when is_binary(producer) do
    if String.trim(producer) == "", do: {:error, :no_producer}, else: :ok
  end

  defp check_producer(_), do: {:error, :no_producer}

  defp check_control(control_id) when is_binary(control_id) do
    if String.trim(control_id) == "", do: {:error, :no_control}, else: :ok
  end

  defp check_control(_), do: {:error, :no_control}

  defp check_organization(organization_id) do
    case Ecto.UUID.cast(organization_id) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_organization}
    end
  end

  defp check_time(%DateTime{} = collected_at, %DateTime{} = now) do
    if DateTime.diff(collected_at, now) > @skew_seconds,
      do: {:error, :future_dated},
      else: :ok
  end

  defp check_time(_, _), do: {:error, :malformed_timestamp}
end
