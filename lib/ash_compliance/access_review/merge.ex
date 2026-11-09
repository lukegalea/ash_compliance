# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.AccessReview.Merge do
  @moduledoc """
  Runs sources and merges what they return into one effective-access row per
  person.

  `run_source/3` classifies a source's answer as `:ok`, `:empty`, `:errored` or
  `:malformed`, and never lets a source's failure escape as an exception.
  `merge/1` combines the entries of the sources that answered into rows keyed by
  the normalised person key, each row listing which sources the person appears
  in and the grants each source gave.
  """

  alias AshCompliance.Processes.Canonical

  @default_timeout_ms 30_000

  @type status :: :ok | :empty | :errored | :malformed

  @type result :: %{
          status: status(),
          count: non_neg_integer(),
          detail: String.t() | nil,
          entries: [map()]
        }

  @type row :: %{
          person_key: String.t(),
          sources: [String.t()],
          entitlements: %{String.t() => [map()]},
          entitlement_digest: String.t()
        }

  @doc "Normalises a person key for merging: trimmed and lower-cased."
  @spec normalise_key(term()) :: {:ok, String.t()} | :error
  def normalise_key(key) when is_binary(key) do
    case key |> String.trim() |> String.downcase() do
      "" -> :error
      normal -> {:ok, normal}
    end
  end

  def normalise_key(_), do: :error

  @doc """
  Calls `source.entries(context)` with a timeout and classifies the answer.
  """
  @spec run_source(module(), map(), keyword()) :: result()
  def run_source(source, context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    task =
      Task.async(fn ->
        try do
          {:returned, source.entries(context)}
        rescue
          exception -> {:raised, Exception.message(exception)}
        catch
          kind, reason -> {:raised, "#{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:returned, answer}} -> classify(answer)
      {:ok, {:raised, message}} -> errored("raised: " <> message)
      {:exit, reason} -> errored("exited: " <> inspect(reason))
      nil -> errored("timed out after #{timeout}ms")
    end
  end

  defp classify({:ok, []}),
    do: %{status: :empty, count: 0, detail: "returned no entries", entries: []}

  defp classify({:ok, entries}) when is_list(entries) do
    case normalise_entries(entries) do
      {:ok, normal} -> %{status: :ok, count: length(normal), detail: nil, entries: normal}
      {:error, detail} -> malformed(detail)
    end
  end

  defp classify({:ok, _other}), do: malformed("entries are not a list")
  defp classify({:error, reason}), do: errored("returned an error: " <> inspect(reason, limit: 5))
  defp classify(other), do: malformed("unexpected return " <> inspect(other, limit: 5))

  defp normalise_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case normalise_entry(entry) do
        {:ok, normal} -> {:cont, {:ok, [normal | acc]}}
        {:error, why} -> {:halt, {:error, "entry #{index}: #{why}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp normalise_entry(%{person_key: key, grants: grants}) when is_list(grants) do
    with {:ok, person} <- key_or_error(key),
         {:ok, normal} <- normalise_grants(grants) do
      {:ok, %{person_key: person, grants: normal}}
    end
  end

  defp normalise_entry(_), do: {:error, "not an entry with a person_key and grants"}

  defp key_or_error(key) do
    case normalise_key(key) do
      {:ok, person} -> {:ok, person}
      :error -> {:error, "person_key is blank or not text"}
    end
  end

  defp normalise_grants([]), do: {:error, "a person is listed with no grants"}

  defp normalise_grants(grants) do
    Enum.reduce_while(grants, {:ok, []}, fn grant, {:ok, acc} ->
      case normalise_grant(grant) do
        {:ok, normal} -> {:cont, {:ok, [normal | acc]}}
        :error -> {:halt, {:error, "a grant has no ref or cannot be encoded"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.sort_by(&Canonical.encode!/1)}
      error -> error
    end
  end

  defp normalise_grant(%{} = grant) when not is_struct(grant) do
    stringified = Map.new(grant, fn {k, v} -> {to_string(k), v} end)

    with ref when is_binary(ref) <- Map.get(stringified, "ref"),
         true <- String.trim(ref) != "",
         {:ok, normal} <- jsonable(stringified) do
      {:ok, normal}
    else
      _ -> :error
    end
  end

  defp normalise_grant(_), do: :error

  defp jsonable(map) do
    {:ok, map |> Canonical.encode!() |> Jason.decode!()}
  rescue
    _ -> :error
  end

  defp errored(detail), do: %{status: :errored, count: 0, detail: detail, entries: []}
  defp malformed(detail), do: %{status: :malformed, count: 0, detail: detail, entries: []}

  @doc """
  Merges `{source_id, entries}` pairs into rows, one per normalised person key,
  ordered by key. Pass only the sources that answered `:ok`.
  """
  @spec merge([{String.t(), [map()]}]) :: [row()]
  def merge(by_source) do
    by_source
    |> Enum.flat_map(fn {source_id, entries} ->
      Enum.map(entries, &{&1.person_key, source_id, &1.grants})
    end)
    |> Enum.group_by(&elem(&1, 0), fn {_, source_id, grants} -> {source_id, grants} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {person_key, pairs} ->
      entitlements =
        Enum.reduce(pairs, %{}, fn {source_id, grants}, acc ->
          Map.update(acc, source_id, grants, &(&1 ++ grants))
        end)

      %{
        person_key: person_key,
        sources: entitlements |> Map.keys() |> Enum.sort(),
        entitlements: entitlements,
        entitlement_digest: digest(entitlements)
      }
    end)
  end

  @doc "The digest a row's entitlements are bound to."
  @spec digest(map()) :: String.t()
  def digest(entitlements), do: Canonical.sha256(entitlements)
end
