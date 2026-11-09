# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Declaration do
  @moduledoc """
  `use` this to declare a boundary.

      defmodule MyHost.Boundary do
        use AshCompliance.Boundary.Declaration

        boundary do
          name "my-host"
          output_dir "priv/boundary"
        end

        environments do
          environment :production do
            class :audited
            zone "zone-a"
          end

          environment :preview do
            class :excluded
            data_ceiling :synthetic
          end
        end

        resources do
          resource :load_balancer do
            environment :production
            kind :managed
            type "aws_lb"
            attributes %{"internal" => false}
          end
        end

        controls do
          control "CC6.6" do
            resources [:load_balancer]
            evidence ["infra.verify:tls_listener"]
          end
        end
      end

  See `AshCompliance.Boundary` for the options and what is generated.
  """

  use Spark.Dsl, default_extensions: [extensions: [AshCompliance.Boundary]]
end
