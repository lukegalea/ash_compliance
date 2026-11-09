# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.AccessReview.Source do
  @moduledoc """
  A place access is granted from, as seen by an access review.

  A host implements one module per authority: its own application grants, a
  legacy system's role table, a code host's team membership, a cloud account's
  role assignments, a workstation platform's accounts, API key owners. The
  campaign asks each source what it grants and merges the answers into one
  effective-access row per person.

  ## Entries

  `entries/1` returns `{:ok, entries}` where each entry is a map with

    * `:person_key` - a non-blank string that identifies the person in this
      source. Keys from different sources are merged when they are equal after
      trimming and lower-casing, so sources should agree on one identifier
      (an email address is typical)
    * `:grants` - a non-empty list of grants, each a map with a non-blank
      `:ref` (what is granted) and any other JSON-encodable detail

  ## What counts as an answer

  A source is trusted only when it returns a non-empty list of well-formed
  entries. Everything else makes the campaign incomplete:

    * `{:error, reason}`, a raise, a throw, an exit or a timeout (`:errored`)
    * `{:ok, []}` (`:empty`): a source that lists nobody is more likely broken
      than correct, and an empty review can never pass
    * anything that is not a list of well-formed entries (`:malformed`)

  An incomplete campaign cannot be closed.
  """

  @type grant :: %{required(:ref) => String.t(), optional(atom() | String.t()) => term()}
  @type entry :: %{person_key: String.t(), grants: [grant()]}

  @typedoc "What the campaign tells a source about the review it is part of."
  @type context :: %{
          organization_id: String.t(),
          as_of: DateTime.t(),
          options: map()
        }

  @doc "The stable identifier of this source, used in the campaign and the evidence."
  @callback id() :: String.t()

  @doc "Everyone this source grants anything to, with what it grants."
  @callback entries(context()) :: {:ok, [entry()]} | {:error, term()}
end
