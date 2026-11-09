# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Controls.Rules do
  @moduledoc """
  The checks the `controls` section must pass to compile.

  A control is satisfied only by a resource declared in an audited
  environment, and an audited environment is a declared production one. A
  resource in any other environment never satisfies a control, and a
  reference to an undeclared resource satisfies nothing.
  """

  alias AshCompliance.Boundary.Controls.Control
  alias AshCompliance.Boundary.{Environment, Resource, Rules}

  @type declaration :: %{
          environments: [Environment.t()],
          resources: [Resource.t()],
          controls: [Control.t()],
          audited_environments: [atom()] | nil
        }

  @doc "Every violation, as a message. An empty list means the section passes."
  @spec violations(declaration()) :: [String.t()]
  def violations(%{} = decl) do
    envs = Map.new(decl.environments, &{&1.name, &1})
    resources = Map.new(decl.resources, &{&1.name, &1})
    audited = decl.audited_environments

    Enum.concat([
      audited_problems(audited, decl.controls, envs),
      Rules.duplicates("control", Enum.map(decl.controls, & &1.criterion)),
      Enum.flat_map(decl.controls, &control(&1, resources, envs, List.wrap(audited)))
    ])
  end

  defp audited_problems(nil, [], _envs), do: []

  defp audited_problems(nil, _controls, _envs),
    do: ["controls are declared but audited_environments is missing"]

  defp audited_problems([], [], _envs), do: []

  defp audited_problems([], _controls, _envs),
    do: ["controls are declared but audited_environments is empty"]

  defp audited_problems(names, _controls, envs) when is_list(names) do
    Rules.duplicates("audited environment", names) ++
      Enum.flat_map(Enum.uniq(names), fn name ->
        case Map.get(envs, name) do
          nil ->
            ["audited environment #{inspect(name)} is not declared"]

          %Environment{class: :production} ->
            []

          %Environment{} ->
            ["audited environment #{inspect(name)} is not a production environment"]
        end
      end)
  end

  defp control(%Control{} = c, resources, envs, audited) do
    undeclared =
      c.resources
      |> Enum.reject(&Map.has_key?(resources, &1))
      |> Enum.map(
        &"control #{inspect(c.criterion)} references undeclared resource #{inspect(&1)}"
      )

    satisfying =
      Enum.filter(c.resources, fn name ->
        with %Resource{environment: env} <- Map.get(resources, name),
             true <- env in audited,
             %Environment{class: :production} <- Map.get(envs, env) do
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
      if c.evidence == [] or Enum.any?(c.evidence, &(not is_binary(&1) or Rules.blank?(&1))),
        do: ["control #{inspect(c.criterion)} needs at least one non-blank evidence reference"],
        else: []

    criterion =
      if Rules.blank?(c.criterion), do: ["a control has a blank criterion"], else: []

    criterion ++ undeclared ++ no_resource ++ evidence
  end
end
