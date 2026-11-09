# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.Frequency do
  @moduledoc """
  How often a control's evidence must be refreshed, and how old evidence may
  be before it stops counting.

  The window is the period plus a grace margin so that a run which is a few
  hours late is not reported as a gap. A frequency this module does not know
  has no window, and the caller must treat that as unknown, never as fresh.
  """

  @day 86_400

  @windows %{
    "continuous" => 1 * @day,
    "daily" => 2 * @day,
    "weekly" => 9 * @day,
    "monthly" => 35 * @day,
    "quarterly" => 100 * @day,
    "semiannual" => 190 * @day,
    "annual" => 380 * @day
  }

  @doc "The accepted frequency names."
  @spec names() :: [String.t()]
  def names, do: @windows |> Map.keys() |> Enum.sort()

  @doc "True for a frequency name this module knows."
  @spec valid?(term()) :: boolean()
  def valid?(name), do: is_binary(name) and Map.has_key?(@windows, name)

  @doc "The seconds evidence stays fresh for, or `:error` for an unknown frequency."
  @spec window_seconds(term()) :: {:ok, pos_integer()} | :error
  def window_seconds(name) when is_binary(name), do: Map.fetch(@windows, name)
  def window_seconds(_), do: :error

  @doc """
  True when the frequency is a human or scheduled cadence rather than
  continuous automation, so a named operating process is expected.
  """
  @spec recurring?(term()) :: boolean()
  def recurring?(name), do: valid?(name) and name != "continuous"
end
