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
  update or destroy, so a correction is a new artifact. The content itself is
  not stored unless the caller passes `store_content: true`; the row pins its
  hash either way. Stored bytes are checked against the hash at create, and
  `verify/1` re-checks them later.

  Nothing is recorded when collection fails. A producer that errors, raises,
  or returns empty content leaves no artifact behind, so the control reads as
  stale or missing rather than as evidenced by something that never ran.
  """

  alias AshCompliance.Domain

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
  (default `false`; keep the bytes on the row).

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
        content: if(Keyword.get(opts, :store_content, false) == true, do: content),
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
