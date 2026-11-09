# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Boundary.Declaration do
  @moduledoc """
  `use` this to declare environments, resources and the controls that cover
  them. It includes both `AshCompliance.Boundary` and
  `AshCompliance.Boundary.Controls`.

      defmodule MyHost.Boundary do
        use AshCompliance.Boundary.Declaration

        boundary do
          name "my-host"
          output_dir "priv/boundary"
        end

        environments do
          environment :production do
            class :production
            zone "zone-a"
          end

          environment :preview do
            class :non_production
            data_ceiling :synthetic
          end
        end

        resources do
          resource :load_balancer do
            environment :production
            kind :managed
            type "lb"
            attributes %{"internal" => false}
          end
        end

        controls do
          audited_environments [:production]

          control "CC6.6" do
            resources [:load_balancer]
            evidence ["infra.verify:tls_listener"]
          end
        end
      end

  A declaration with no controls does not need this module. It uses the
  production extension alone, through `AshCompliance.Boundary.Production`:

      use AshCompliance.Boundary.Production

  See `AshCompliance.Boundary` and `AshCompliance.Boundary.Controls` for the
  options and what is generated.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [AshCompliance.Boundary, AshCompliance.Boundary.Controls]]
end
