# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Processes.Decisions do
  @moduledoc """
  The DMN documents shipped under `priv/decisions/`.

  `separation_of_duties` answers whether an approver may approve a requester's
  request. `triage_routing` routes a finding by severity. Both are documents
  first: a host publishes them under the keys in `AshCompliance.Processes.Templates.decisions/0`
  so the business rule tasks in the templates resolve, and
  `AshCompliance.Processes.SeparationOfDuties` evaluates the shipped separation
  document directly, pinned by its hash, so editing a published copy cannot
  weaken the gate that refuses self-approval.
  """

  @decisions %{
    "compliance.separation_of_duties" => {"separation_of_duties.dmn", "SeparationOfDuties"},
    "compliance.triage_routing" => {"triage_routing.dmn", "TriageRoute"}
  }

  @doc "The decision references this package ships a document for."
  @spec keys() :: [String.t()]
  def keys, do: @decisions |> Map.keys() |> Enum.sort()

  @doc "True when `key` is a shipped decision."
  @spec exists?(term()) :: boolean()
  def exists?(key), do: is_binary(key) and Map.has_key?(@decisions, key)

  @doc "The DMN XML for a shipped decision."
  @spec xml(String.t()) :: String.t()
  def xml(key), do: key |> path() |> File.read!()

  @doc "The decision name inside the document."
  @spec decision_name(String.t()) :: String.t()
  def decision_name(key), do: key |> fetch!() |> elem(1)

  @doc "SHA-256 (hex) of the document."
  @spec content_hash(String.t()) :: String.t()
  def content_hash(key), do: key |> xml() |> AshCompliance.Ownership.Evidence.sha256()

  @doc "Absolute path of the document."
  @spec path(String.t()) :: Path.t()
  def path(key) do
    {file, _} = fetch!(key)
    Application.app_dir(:ash_compliance, Path.join(["priv", "decisions", file]))
  end

  @doc """
  A definition-shaped map the decision engine can evaluate without a database:
  the key, version 1, the document and its hash.
  """
  @spec definition(String.t()) :: map()
  def definition(key) do
    %{key: key, version: 1, xml: xml(key), content_hash: content_hash(key), graph: nil}
  end

  defp fetch!(key) do
    Map.get(@decisions, key) || raise ArgumentError, "unknown decision #{inspect(key)}"
  end
end
