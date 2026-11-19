# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.BundleForm do
  @moduledoc false

  # One spelling for every bundle a caller hands this package.
  #
  # A bundle compiled from the `AshRules` DSL keeps the terms it was written
  # with: `has(:application, ...)` holds the atom `:application`. The same
  # bundle read back from storage has been through JSON, where subject terms
  # are opaque, so it holds the string `"application"`, which is the spelling the
  # `AshCompliance.FactBuilder` contract tells hosts to emit. Evaluating the
  # first form against contract-shaped facts reads every rule as not
  # applicable.
  #
  # `normalize/1` puts a passed bundle through the IR codec (encode, then
  # decode with the verifiers), so a freshly compiled bundle and its stored
  # form evaluate identically. The content hash is computed over the canonical
  # JSON, which is the same before and after, so the hash and the revision
  # survive the trip; on an already-decoded bundle the trip is a no-op.

  alias AshCompliance.Resources.PolicyBundle
  alias AshRules.Ir

  @doc false
  @spec normalize(Ir.Bundle.t()) :: {:ok, Ir.Bundle.t()} | {:error, {:invalid_bundle, term()}}
  def normalize(%Ir.Bundle{} = bundle) do
    with {:ok, json} <- encode(bundle),
         {:ok, decoded} <- Ir.decode(json) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:invalid_bundle, reason}}
    end
  end

  @doc false
  # The bundle forms a caller may pass: a decoded or DSL-compiled IR bundle
  # (normalised), or a stored `PolicyBundle` (decoded from its JSON, which is
  # already in the stored spelling; a decode failure keeps its existing
  # `{:error, reason}` shape).
  @spec resolve(term()) :: {:ok, Ir.Bundle.t()} | {:error, term()}
  def resolve(%Ir.Bundle{} = bundle), do: normalize(bundle)
  def resolve(%PolicyBundle{rules_json: rules_json}), do: Ir.decode(rules_json)
  def resolve(other), do: {:error, {:invalid_bundle, other}}

  # `Jason.encode/1` returns an error tuple for invalid strings but raises for a
  # term it has no encoder for (a tuple in a predicate value, say).
  defp encode(bundle) do
    Ir.encode(bundle)
  rescue
    error -> {:error, Exception.message(error)}
  end
end
