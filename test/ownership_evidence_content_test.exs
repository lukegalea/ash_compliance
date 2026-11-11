# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.OwnershipEvidenceContentTest do
  @moduledoc """
  An artifact can keep the bytes its hash pins, so the hash can always be re-checked.
  Content is opt-in; when kept it must match the hash, and a row never changes.
  """

  use AshCompliance.DataCase, async: false

  alias AshCompliance.Domain
  alias AshCompliance.Ownership.Evidence

  @now ~U[2026-11-10 12:00:00.000000Z]

  defp record(content, opts \\ []) do
    Evidence.record(
      Ecto.UUID.generate(),
      "CC6.1",
      content,
      Keyword.merge([producer: "module:P", now: @now], opts)
    )
  end

  test "content is stored by default, and a hash-only artifact does not verify" do
    assert {:ok, artifact} = record("{\"a\":1}")
    assert artifact.content == "{\"a\":1}"
    assert :ok = Evidence.verify(artifact)

    assert {:ok, bare} = record("{\"a\":2}", store_content: false)
    assert bare.content == nil
    assert {:error, :no_content} = Evidence.verify(bare)
  end

  test "store_content keeps the bytes and verify re-checks them against the hash" do
    assert {:ok, artifact} = record("{\"a\":1}", store_content: true)
    assert artifact.content == "{\"a\":1}"
    assert artifact.hash == Evidence.sha256("{\"a\":1}")
    assert :ok = Evidence.verify(artifact)

    {:ok, reread} = Domain.get_evidence_artifact_by_id(artifact.id, authorize?: false)
    assert reread.content == "{\"a\":1}"
    assert :ok = Evidence.verify(reread)
  end

  test "bytes that do not match the hash are refused at create" do
    attrs = %{
      organization_id: Ecto.UUID.generate(),
      control_id: "CC6.1",
      hash: Evidence.sha256("one"),
      content: "two",
      media_type: "text/plain",
      collector: "module:P",
      method: :examine,
      collected_at: @now
    }

    assert {:error, _} = Domain.create_evidence_artifact(attrs, authorize?: false)
  end

  test "verify never passes a tampered struct" do
    {:ok, artifact} = record("abc", store_content: true)
    assert {:error, :hash_mismatch} = Evidence.verify(%{artifact | content: "abd"})
    assert {:error, :no_content} = Evidence.verify(%{artifact | content: ""})
  end

  test "the evidence resource has no update or destroy action" do
    names =
      AshCompliance.Resources.EvidenceArtifact
      |> Ash.Resource.Info.actions()
      |> Enum.map(& &1.type)

    refute :update in names
    refute :destroy in names
  end
end
