# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Rules do
  @moduledoc """
  The checks the environments and resources of a declaration must pass to
  compile.

  An environment is `:production`, or `:non_production` under a data ceiling.
  A declaration that fails any rule does not compile.
  """

  alias AshCompliance.Boundary.{Environment, Resource}

  @type declaration :: %{
          name: term(),
          environments: [Environment.t()],
          resources: [Resource.t()]
        }

  @doc "Every violation, as a message. An empty list means the declaration passes."
  @spec violations(declaration()) :: [String.t()]
  def violations(%{} = decl) do
    envs = Map.new(decl.environments, &{&1.name, &1})

    Enum.concat([
      boundary_name(decl.name),
      duplicates("environment", Enum.map(decl.environments, & &1.name)),
      duplicates("resource", Enum.map(decl.resources, & &1.name)),
      Enum.flat_map(decl.environments, &environment/1),
      Enum.flat_map(decl.resources, &resource(&1, envs))
    ])
  end

  @doc "True when `value` is nil, not a string, or only whitespace."
  @spec blank?(term()) :: boolean()
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_), do: true

  @doc "Duplicate-name messages for `kind`, sorted."
  @spec duplicates(String.t(), [term()]) :: [String.t()]
  def duplicates(kind, names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_, n} -> n > 1 end)
    |> Enum.map(fn {name, _} -> "#{kind} #{inspect(name)} is declared more than once" end)
    |> Enum.sort()
  end

  defp boundary_name(name) when is_binary(name) do
    if blank?(name), do: ["the boundary needs a non-blank name"], else: []
  end

  defp boundary_name(_), do: ["the boundary needs a non-blank name"]

  defp environment(%Environment{} = env) do
    class_problem(env) ++ ceiling_problem(env) ++ zone_problem(env.name, env.zone)
  end

  defp class_problem(%Environment{class: class}) when class in [:production, :non_production],
    do: []

  defp class_problem(%Environment{class: class, name: name}),
    do: [
      "environment #{inspect(name)} has class #{inspect(class)}; it must be :production or :non_production"
    ]

  defp ceiling_problem(%Environment{class: :non_production, data_ceiling: nil, name: name}),
    do: ["non-production environment #{inspect(name)} has no data ceiling"]

  defp ceiling_problem(%Environment{class: :production, data_ceiling: ceiling, name: name})
       when not is_nil(ceiling),
       do: [
         "production environment #{inspect(name)} declares a data ceiling; only a non-production one has one"
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
end
