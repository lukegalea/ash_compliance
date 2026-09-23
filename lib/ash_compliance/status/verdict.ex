# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Status.Verdict do
  @moduledoc """
  The verdict for one rule of the active bundle, as a status surface needs it.

  A slim projection of `AshRules.Result.Requirement` — the engine's full
  provenance unit — down to the fields a badge or a "why" tooltip quotes:
  which rule spoke (`rule_id`), how loudly (`severity`), what it demands
  (`gap`, the same text the guard quotes on refusals), what it decided
  (`status`), and its own wording (`message`).
  """

  defstruct [:rule_id, :severity, :gap, :status, :message]

  @type status() ::
          :compliant | :noncompliant | :not_applicable | :unknown | :error

  @type t() :: %__MODULE__{
          rule_id: String.t(),
          severity: AshRules.Ir.Rule.severity() | nil,
          gap: String.t() | nil,
          status: status(),
          message: String.t() | nil
        }

  @doc false
  @spec new(AshRules.Result.Requirement.t()) :: t()
  def new(%AshRules.Result.Requirement{} = requirement) do
    %__MODULE__{
      rule_id: requirement.rule_id,
      severity: requirement.severity,
      gap: requirement.gap,
      status: requirement.outcome,
      message: requirement.message
    }
  end
end
