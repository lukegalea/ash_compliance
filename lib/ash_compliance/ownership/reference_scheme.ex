# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Ownership.ReferenceScheme do
  @moduledoc """
  A reference scheme a host adds to the control file, beside the built-in
  `module:`, `mix:` and `file:` (`AshCompliance.Ownership.Resolver`).

  A host whose proof lives in something this package cannot see (a declared
  journey, a pipeline the host runs) names it as `scheme:value` and says how
  such a reference resolves and what it proves:

      config :ash_compliance, reference_schemes: %{"journey" => MyApp.JourneyReference}

  Both callbacks receive the value after the scheme's colon. They must never
  create atoms from it, and must answer from what is on disk or compiled, not
  from a database: the check runs in CI with nothing started.

  A built-in scheme cannot be replaced; a configured `module`, `mix` or `file`
  is never consulted.
  """

  @doc """
  Whether the reference `value` names something that exists and holds, relative
  to the host root `root`. The message says why not.
  """
  @callback resolve(value :: String.t(), root :: Path.t()) :: :ok | {:error, String.t()}

  @doc """
  Whether the producer `value` declares that it records evidence for
  `criterion` (`AshCompliance.Ownership.Resolver.proves_producer/2`).
  """
  @callback proves_producer(value :: String.t(), criterion :: String.t()) ::
              :ok | {:error, String.t()}
end
