# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.EvidenceArtifact.Validations.ContentMatchesHash do
  @moduledoc """
  When an artifact carries its bytes, they must hash to the recorded SHA-256. An artifact
  whose stored bytes disagree with its hash is refused at create, so a stored row can
  always be re-verified.
  """

  use Ash.Resource.Validation

  alias AshCompliance.Ownership.Evidence

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :content) do
      nil ->
        :ok

      content when is_binary(content) ->
        if Evidence.sha256(content) == Ash.Changeset.get_attribute(changeset, :hash),
          do: :ok,
          else: {:error, field: :content, message: "does not match the artifact hash"}
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
