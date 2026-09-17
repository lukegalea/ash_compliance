# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.PolicyBundle.CompileChange do
  @moduledoc false

  # The `compile` create-change and the `activate` validate-before-activate
  # change.
  #
  # `compile` resolves the layers through `AshCompliance.Compiler` inside the
  # action, so the stored bundle always reflects layer state at compile time.
  # `activate` re-decodes the stored JSON through `AshRules.Ir.decode/1`
  # (full verifiers) before the bundle may go live.

  use Ash.Resource.Change

  alias AshCompliance.Compiler
  alias AshRules.Ir

  @impl true
  def change(changeset, opts, _context) do
    if opts[:stage] == :activate do
      validate_before_activate(changeset)
    else
      compile(changeset)
    end
  end

  defp compile(changeset) do
    organization_id =
      Ash.Changeset.get_argument(changeset, :organization_id) ||
        Ash.Changeset.get_attribute(changeset, :organization_id)

    now = Ash.Changeset.get_argument(changeset, :now)

    Ash.Changeset.before_action(changeset, fn changeset ->
      case Compiler.compile(organization_id: organization_id, now: now) do
        {:ok, bundle, lineage} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:rules_json, Ir.encode!(bundle))
          |> Ash.Changeset.force_change_attribute(:content_hash, bundle.content_hash)
          |> Ash.Changeset.force_change_attribute(:manifest_revision, bundle.revision)
          |> Ash.Changeset.force_change_attribute(:compiler_version, bundle.compiler_version)
          |> Ash.Changeset.force_change_attribute(:contributions, lineage)

        {:error, errors} ->
          Enum.reduce(List.wrap(errors), changeset, &Ash.Changeset.add_error(&2, &1))
      end
    end)
  end

  defp validate_before_activate(changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      rules_json = Ash.Changeset.get_attribute(changeset, :rules_json)

      case Ir.decode(rules_json) do
        {:ok, _bundle} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :active)
          |> Ash.Changeset.force_change_attribute(
            :active_at,
            DateTime.utc_now() |> DateTime.truncate(:second)
          )

        {:error, errors} ->
          message =
            "bundle #{Ash.Changeset.get_attribute(changeset, :content_hash)} no longer decodes: " <>
              (errors |> List.wrap() |> Enum.join("; "))

          Ash.Changeset.add_error(changeset, message)
      end
    end)
  end
end
