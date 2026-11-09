# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Rules do
  @moduledoc """
  The checks a boundary declaration must pass to compile.

  A control is satisfied only by a resource declared in an audited
  environment. A resource in an excluded environment never satisfies one, and
  a reference to an undeclared resource satisfies nothing. A declaration that
  fails any rule does not compile.
  """

  alias AshCompliance.Boundary.{Control, Environment, Resource}

  @type declaration :: %{
          name: term(),
          environments: [Environment.t()],
          resources: [Resource.t()],
          controls: [Control.t()]
        }

  @doc "Every violation, as a message. An empty list means the declaration passes."
  @spec violations(declaration()) :: [String.t()]
  def violations(%{} = decl) do
    envs = Map.new(decl.environments, &{&1.name, &1})
    resources = Map.new(decl.resources, &{&1.name, &1})

    Enum.concat([
      boundary_name(decl.name),
      duplicates("environment", Enum.map(decl.environments, & &1.name)),
      duplicates("resource", Enum.map(decl.resources, & &1.name)),
      duplicates("control", Enum.map(decl.controls, & &1.criterion)),
      Enum.flat_map(decl.environments, &environment/1),
      Enum.flat_map(decl.resources, &resource(&1, envs)),
      Enum.flat_map(decl.controls, &control(&1, resources, envs))
    ])
  end

  defp boundary_name(name) when is_binary(name) do
    if blank?(name), do: ["the boundary needs a non-blank name"], else: []
  end

  defp boundary_name(_), do: ["the boundary needs a non-blank name"]

  defp duplicates(kind, names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_, n} -> n > 1 end)
    |> Enum.map(fn {name, _} -> "#{kind} #{inspect(name)} is declared more than once" end)
    |> Enum.sort()
  end

  defp environment(%Environment{} = env) do
    ceiling_problem(env) ++ zone_problem(env.name, env.zone)
  end

  defp ceiling_problem(%Environment{class: :excluded, data_ceiling: nil, name: name}),
    do: ["excluded environment #{inspect(name)} has no data ceiling"]

  defp ceiling_problem(%Environment{class: :audited, data_ceiling: ceiling, name: name})
       when not is_nil(ceiling),
       do: [
         "audited environment #{inspect(name)} declares a data ceiling; only an excluded one has one"
       ]

  defp ceiling_problem(_), do: []

  defp zone_problem(name, zone) when is_binary(zone) do
    if blank?(zone) or String.match?(zone, ~r/\s/) do
      ["environment #{inspect(name)} has a zone id that is blank or contains whitespace"]
    else
      []
    end
  end

  defp zone_problem(_name, _zone), do: []

  defp resource(%Resource{} = r, envs) do
    env_problem =
      if Map.has_key?(envs, r.environment),
        do: [],
        else: [
          "resource #{inspect(r.name)} is in undeclared environment #{inspect(r.environment)}"
        ]

    type_problem =
      if r.kind == :managed and (not is_binary(r.type) or blank?(r.type)),
        do: ["managed resource #{inspect(r.name)} has no type"],
        else: []

    env_problem ++ type_problem ++ attribute_problems(r)
  end

  defp attribute_problems(%Resource{name: name, attributes: attrs}) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {k, v} ->
      is_binary(k) and (is_binary(v) or is_boolean(v) or is_integer(v))
    end)
    |> Enum.map(fn {k, _} ->
      "resource #{inspect(name)} attribute #{inspect(k)} must have a string key and a string, boolean or integer value"
    end)
    |> Enum.sort()
  end

  defp attribute_problems(%Resource{name: name}),
    do: ["resource #{inspect(name)} attributes must be a map"]

  defp control(%Control{} = c, resources, envs) do
    undeclared =
      c.resources
      |> Enum.reject(&Map.has_key?(resources, &1))
      |> Enum.map(
        &"control #{inspect(c.criterion)} references undeclared resource #{inspect(&1)}"
      )

    satisfying =
      Enum.filter(c.resources, fn name ->
        with %Resource{environment: env} <- Map.get(resources, name),
             %Environment{class: :audited} <- Map.get(envs, env) do
          true
        else
          _ -> false
        end
      end)

    no_resource =
      if satisfying == [],
        do: ["control #{inspect(c.criterion)} has no resource in an audited environment"],
        else: []

    evidence =
      if c.evidence == [] or Enum.any?(c.evidence, &(not is_binary(&1) or blank?(&1))),
        do: ["control #{inspect(c.criterion)} needs at least one non-blank evidence reference"],
        else: []

    criterion =
      if blank?(c.criterion), do: ["a control has a blank criterion"], else: []

    criterion ++ undeclared ++ no_resource ++ evidence
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true
end
