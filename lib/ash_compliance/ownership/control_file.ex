# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.ControlFile do
  @moduledoc """
  Reads a host's control file and exposes the per-criterion ownership rows.

  The ownership rows live under a top-level `"criteria"` key, beside whatever
  else the file already carries (`"frameworks"`, `"controls"`, `"$comment"`).
  Files without a `"criteria"` key stay valid JSON documents; the checker
  simply reports every criterion as missing.

  Each row is an object:

      {
        "id": "CC6.1",
        "class": "PLATFORM-ENFORCED",
        "applicability": "applicable",
        "frequency": "continuous",
        "owner_role": "Head of Engineering",
        "evidence_producer": "module:MyApp.Evidence.AccessSnapshot",
        "operating_process": "file:docs/runbooks/access-review.md",
        "test_ref": "file:test/my_app/access_test.exs",
        "vendor_ref": "Hosting provider SOC 2 report",
        "complementary_controls": ["CC6.2"],
        "rationale": "required when applicability is not_applicable"
      }

  Classes: `PLATFORM-ENFORCED`, `PLATFORM-EVIDENCED`, `HOST-APP`, `INFRA`,
  `VENDOR`, `ORG`. Applicability: `applicable` or `not_applicable`.

  A row never carries a `status`. Status is derived from evidence at read time
  and a stored one would be a claim nothing keeps true, so the checker rejects
  the key.
  """

  @classes ~w(PLATFORM-ENFORCED PLATFORM-EVIDENCED HOST-APP INFRA VENDOR ORG)
  @applicability ~w(applicable not_applicable)
  @keys ~w(id class applicability frequency owner_role evidence_producer
           operating_process test_ref vendor_ref complementary_controls rationale)

  @type load_error ::
          {:missing, Path.t()}
          | {:unreadable, Path.t(), term()}
          | {:malformed_json, String.t()}
          | {:malformed, String.t()}

  @doc "The accepted class names."
  @spec classes() :: [String.t()]
  def classes, do: @classes

  @doc "The accepted applicability values."
  @spec applicability_values() :: [String.t()]
  def applicability_values, do: @applicability

  @doc "The keys a row may carry."
  @spec row_keys() :: [String.t()]
  def row_keys, do: @keys

  @doc """
  Loads and parses the file. Returns the whole document and its ownership
  rows, or an error that names why nothing can be trusted.
  """
  @spec load(Path.t()) :: {:ok, %{document: map(), rows: [term()]}} | {:error, load_error()}
  def load(path) do
    case File.read(path) do
      {:ok, body} -> parse(body)
      {:error, :enoent} -> {:error, {:missing, path}}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  @doc "Parses file content."
  @spec parse(String.t()) :: {:ok, %{document: map(), rows: [term()]}} | {:error, load_error()}
  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> rows(document)
      {:ok, _other} -> {:error, {:malformed, "the document is not a JSON object"}}
      {:error, error} -> {:error, {:malformed_json, Exception.message(error)}}
    end
  end

  defp rows(document) do
    case Map.fetch(document, "criteria") do
      :error -> {:ok, %{document: document, rows: []}}
      {:ok, rows} when is_list(rows) -> {:ok, %{document: document, rows: rows}}
      {:ok, _} -> {:error, {:malformed, "\"criteria\" is not a list"}}
    end
  end

  @doc "A human sentence for a load error."
  @spec describe_error(load_error()) :: String.t()
  def describe_error({:missing, path}), do: "control file #{path} does not exist"

  def describe_error({:unreadable, path, reason}),
    do: "control file #{path} unreadable: #{inspect(reason)}"

  def describe_error({:malformed_json, message}), do: "control file is not valid JSON: #{message}"
  def describe_error({:malformed, message}), do: "control file is malformed: #{message}"
end
