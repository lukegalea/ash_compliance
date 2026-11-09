# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Render do
  @moduledoc """
  Turns the environments and resources of a declaration into their files.

  Pure and deterministic: the files depend only on the declared facts, never
  on declaration order, the clock or the host.
  """

  alias AshCompliance.Boundary.Json

  @tfvars "boundary.auto.tfvars.json"
  @assertions "infra.assertions.json"
  @snapshot "boundary.snapshot.json"

  @doc "The file names this renderer produces."
  @spec file_names() :: [String.t()]
  def file_names, do: Enum.sort([@assertions, @tfvars, @snapshot])

  @doc "A map of file name to contents."
  @spec files(map()) :: %{String.t() => String.t()}
  def files(%{} = decl) do
    %{
      @tfvars => Json.encode(tfvars(decl)),
      @assertions => Json.encode(assertions(decl)),
      @snapshot => Json.encode(snapshot(decl))
    }
  end

  defp tfvars(decl) do
    by_env = fn kind ->
      base = Map.new(decl.environments, &{&1.name, []})

      decl.resources
      |> Enum.filter(&(&1.kind == kind))
      |> Enum.group_by(& &1.environment, & &1.name)
      |> then(&Map.merge(base, &1))
      |> Map.new(fn {env, names} -> {env, names |> Enum.map(&to_string/1) |> Enum.sort()} end)
    end

    %{
      boundary_production_environments: production_names(decl.environments),
      boundary_non_production_environments:
        decl.environments
        |> Enum.filter(&(&1.class == :non_production))
        |> Map.new(&{&1.name, %{data_ceiling: &1.data_ceiling}}),
      boundary_managed_resources: by_env.(:managed),
      boundary_data_sources: by_env.(:data_source),
      boundary_zones:
        decl.environments
        |> Enum.reject(&is_nil(&1.zone))
        |> Map.new(&{&1.name, &1.zone})
    }
  end

  defp assertions(decl) do
    resource_assertions =
      Enum.map(decl.resources, fn
        %{kind: :managed} = r ->
          %{
            id: "resource.#{r.environment}.#{r.name}",
            kind: "resource_present",
            environment: r.environment,
            resource: r.name,
            type: r.type,
            attributes: r.attributes
          }

        %{kind: :data_source} = r ->
          %{
            id: "resource.#{r.environment}.#{r.name}",
            kind: "data_source_declared",
            environment: r.environment,
            resource: r.name
          }
      end)

    ceiling_assertions =
      for e <- decl.environments, e.class == :non_production do
        %{
          id: "environment.#{e.name}.data_ceiling",
          kind: "data_ceiling",
          environment: e.name,
          ceiling: e.data_ceiling
        }
      end

    %{
      schema: "boundary.assertions/1",
      boundary: decl.name,
      assertions: Enum.sort_by(resource_assertions ++ ceiling_assertions, & &1.id)
    }
  end

  defp snapshot(decl) do
    %{
      schema: "boundary.snapshot/1",
      boundary: decl.name,
      environments:
        decl.environments
        |> Enum.sort_by(& &1.name)
        |> Enum.map(
          &%{
            name: &1.name,
            class: &1.class,
            data_ceiling: &1.data_ceiling,
            zone: &1.zone
          }
        ),
      resources:
        decl.resources
        |> Enum.sort_by(& &1.name)
        |> Enum.map(
          &%{
            name: &1.name,
            environment: &1.environment,
            kind: &1.kind,
            type: &1.type,
            attributes: &1.attributes
          }
        )
    }
  end

  defp production_names(environments) do
    environments
    |> Enum.filter(&(&1.class == :production))
    |> Enum.map(&to_string(&1.name))
    |> Enum.sort()
  end
end
