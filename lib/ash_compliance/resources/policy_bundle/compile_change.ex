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
  #
  # With no `scheme`/`source`/`context` argument the compile call is exactly
  # the default one (`organization_id` and `now`, nothing else), so the
  # default bundle, hash, revision and lineage are unchanged. A declared
  # scheme is recorded by module name; the default scheme records `nil`.

  use Ash.Resource.Change

  alias AshCompliance.Compiler
  alias AshCompliance.Layering
  alias AshRules.Ir

  @impl true
  def change(changeset, opts, context) do
    if opts[:stage] == :activate do
      validate_before_activate(changeset)
    else
      compile(changeset, context)
    end
  end

  defp compile(changeset, context) do
    organization_id =
      Ash.Changeset.get_argument(changeset, :organization_id) ||
        Ash.Changeset.get_attribute(changeset, :organization_id)

    now = Ash.Changeset.get_argument(changeset, :now)
    declared = declared(changeset, context)
    scheme = Keyword.get(declared, :scheme)

    Ash.Changeset.before_action(changeset, fn changeset ->
      case Compiler.compile([organization_id: organization_id, now: now] ++ declared) do
        {:ok, bundle, lineage} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:rules_json, Ir.encode!(bundle))
          |> Ash.Changeset.force_change_attribute(:content_hash, bundle.content_hash)
          |> Ash.Changeset.force_change_attribute(:manifest_revision, bundle.revision)
          |> Ash.Changeset.force_change_attribute(:compiler_version, bundle.compiler_version)
          |> Ash.Changeset.force_change_attribute(:contributions, contributions(lineage))
          |> Ash.Changeset.force_change_attribute(:scheme, scheme_name(scheme))

        {:error, errors} ->
          Enum.reduce(List.wrap(errors), changeset, &Ash.Changeset.add_error(&2, &1))
      end
    end)
  end

  # The scheme/source/context arguments, only those given. A host source also
  # gets the action's actor, so it can read as the person compiling.
  defp declared(changeset, context) do
    declared =
      for key <- [:scheme, :source, :context],
          value = Ash.Changeset.get_argument(changeset, key),
          not is_nil(value),
          do: {key, value}

    if Keyword.has_key?(declared, :source) and context.actor,
      do: declared ++ [actor: context.actor],
      else: declared
  end

  defp scheme_name(nil), do: nil
  defp scheme_name(Layering.Default), do: nil
  defp scheme_name(scheme), do: inspect(scheme)

  # A source's lineage is stored as it comes; the resolution's per-rule
  # lineage map (a source with no lineage of its own) is flattened into its
  # steps, so `contributions` is always a list of maps.
  defp contributions(lineage) when is_list(lineage), do: lineage

  defp contributions(lineage) when is_map(lineage) do
    lineage
    |> Enum.sort_by(fn {rule_id, _steps} -> rule_id end)
    |> Enum.flat_map(fn {_rule_id, steps} ->
      Enum.map(steps, &Map.take(&1, [:rule_id, :op, :layer, :source_id, :scope, :params]))
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
