# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Render do
  @moduledoc """
  Turns a boundary declaration into its generated files.

  Pure and deterministic: the files depend only on the declared facts, never
  on declaration order, the clock or the host. A control is reported as
  `owned`: the declaration names who carries it. Whether the evidence exists
  is not something a declaration can say.
  """

  alias AshCompliance.Boundary.Json

  @control_map "control-map.json"
  @tfvars "boundary.auto.tfvars.json"
  @assertions "infra.assertions.json"
  @snapshot "boundary.snapshot.json"

  @doc "The file names this renderer produces."
  @spec file_names() :: [String.t()]
  def file_names, do: [@assertions, @tfvars, @control_map, @snapshot] |> Enum.sort()

  @doc "A map of file name to contents."
  @spec files(map()) :: %{String.t() => String.t()}
  def files(%{} = decl) do
    %{
      @control_map => Json.encode(control_map(decl)),
      @tfvars => Json.encode(tfvars(decl)),
      @assertions => Json.encode(assertions(decl)),
      @snapshot => Json.encode(snapshot(decl))
    }
  end

  defp control_map(decl) do
    resources = Map.new(decl.resources, &{&1.name, &1})

    controls =
      decl.controls
      |> Enum.sort_by(& &1.criterion)
      |> Enum.map(fn c ->
        %{
          criterion: c.criterion,
          state: "owned",
          evidence: c.evidence |> Enum.uniq() |> Enum.sort(),
          resources:
            c.resources
            |> Enum.uniq()
            |> Enum.map(&Map.fetch!(resources, &1))
            |> Enum.sort_by(&{to_string(&1.environment), to_string(&1.name)})
            |> Enum.map(&%{name: &1.name, environment: &1.environment, kind: &1.kind})
        }
      end)

    %{schema: "ash_compliance.boundary.control-map/1", boundary: decl.name, controls: controls}
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
      boundary_audited_environments: names_of(decl.environments, :audited),
      boundary_excluded_environments:
        decl.environments
        |> Enum.filter(&(&1.class == :excluded))
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
      for e <- decl.environments, e.class == :excluded do
        %{
          id: "environment.#{e.name}.data_ceiling",
          kind: "data_ceiling",
          environment: e.name,
          ceiling: e.data_ceiling
        }
      end

    %{
      schema: "ash_compliance.boundary.assertions/1",
      boundary: decl.name,
      assertions: Enum.sort_by(resource_assertions ++ ceiling_assertions, & &1.id)
    }
  end

  defp snapshot(decl) do
    %{
      schema: "ash_compliance.boundary.snapshot/1",
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
        ),
      controls:
        decl.controls
        |> Enum.sort_by(& &1.criterion)
        |> Enum.map(
          &%{
            criterion: &1.criterion,
            resources: &1.resources |> Enum.uniq() |> Enum.sort(),
            evidence: &1.evidence |> Enum.uniq() |> Enum.sort()
          }
        )
    }
  end

  defp names_of(environments, class) do
    environments
    |> Enum.filter(&(&1.class == class))
    |> Enum.map(&to_string(&1.name))
    |> Enum.sort()
  end
end
