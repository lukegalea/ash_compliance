# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Test.BoundaryFixture do
  @moduledoc false
  # A generic host. Declared out of alphabetical order on purpose: the
  # generated files must not depend on it.
  use AshCompliance.Boundary.Declaration

  boundary do
    name("fixture-host")
    output_dir("test/fixtures/boundary/expected")
  end

  environments do
    environment :staging do
      class(:non_production)
      data_ceiling(:pseudonymised)
    end

    environment :production do
      class(:production)
      zone("zone-a")
    end

    environment :preview do
      class(:non_production)
      data_ceiling(:synthetic)
    end
  end

  resources do
    resource :preview_app do
      environment(:preview)
      kind(:managed)
      type("compute_app")
    end

    resource :load_balancer do
      environment(:production)
      kind(:managed)
      type("aws_lb")
      attributes(%{"protocol" => "HTTPS", "internal" => false})
    end

    resource :identity_provider do
      environment(:production)
      kind(:data_source)
    end

    resource :app_database do
      environment(:production)
      kind(:managed)
      type("aws_db_instance")
      attributes(%{"storage_encrypted" => true})
    end
  end

  controls do
    audited_environments([:production])

    control "CC6.6" do
      resources([:load_balancer])
      evidence(["infra.verify:tls_listener", "config:alb-https"])
    end

    control "CC6.1" do
      resources([:identity_provider, :app_database])
      evidence(["access-listing.daily"])
    end
  end
end
