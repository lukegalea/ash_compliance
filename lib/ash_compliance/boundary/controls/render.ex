# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Controls.Render do
  @moduledoc """
  Turns the controls of a declaration into their files.

  Pure and deterministic. A control is reported as `owned`: the declaration
  names who carries it. Whether the evidence exists is not something a
  declaration can say.
  """

  alias AshCompliance.Boundary.Json

  @control_map "control-map.json"
  @snapshot "controls.snapshot.json"

  @doc "The file names this renderer produces."
  @spec file_names() :: [String.t()]
  def file_names, do: Enum.sort([@control_map, @snapshot])

  @doc "A map of file name to contents."
  @spec files(map()) :: %{String.t() => String.t()}
  def files(%{} = decl) do
    %{
      @control_map => Json.encode(control_map(decl)),
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

  defp snapshot(decl) do
    %{
      schema: "ash_compliance.boundary.controls-snapshot/1",
      boundary: decl.name,
      audited_environments:
        (decl.audited_environments || []) |> Enum.map(&to_string/1) |> Enum.sort(),
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
end
