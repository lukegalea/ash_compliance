# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Production do
  @moduledoc """
  `use` this to declare environments and resources and nothing else.

      defmodule MyHost.Boundary do
        use AshCompliance.Boundary.Production

        boundary do
          name "my-host"
        end

        environments do
          environment :production do
            class :production
          end
        end

        resources do
          resource :load_balancer do
            environment :production
            kind :managed
            type "lb"
          end
        end
      end

  It is a Spark DSL whose only default extension is `AshCompliance.Boundary`.
  Another extension joins it with Spark's own `extensions` option:
  `use AshCompliance.Boundary.Production, extensions: [OtherExtension]`.
  """

  use Spark.Dsl, default_extensions: [extensions: [AshCompliance.Boundary]]
end
