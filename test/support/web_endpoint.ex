# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# IMPORTANT: definition order is compilation order here. The wrapper LiveView
# must exist before the Router that routes to it, and the Router before the
# Endpoint that plugs it. Same arrangement as ash_decisions' web_endpoint.ex.

defmodule AshCompliance.Web.TestLayout do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>AshCompliance Test</title>
      </head>
      <body>
        <div id="flash-group">
          <div :for={{_key, message} <- @flash}>{message}</div>
        </div>
        <main>{@inner_content}</main>
      </body>
    </html>
    """
  end
end

defmodule AshCompliance.Web.TestOrg do
  @moduledoc false

  # The host-side organization MFA: what a real host supplies instead of
  # hard-coding an organization id everywhere. One fixed org per test run;
  # the SQL sandbox keeps tests from seeing each other's rows.
  @organization_id Ecto.UUID.generate()

  def current_organization(_socket), do: @organization_id

  def organization_id, do: @organization_id
end

defmodule AshCompliance.Web.RulesetEditorWrapper do
  @moduledoc false

  # The host integration the macro exists for: a three-line module naming the
  # domain, the organization source and nothing else.
  use AshCompliance.Web.RulesetEditorLive,
    domain: AshCompliance.Domain,
    organization: {AshCompliance.Web.TestOrg, :current_organization, []}
end

defmodule AshCompliance.Web.TestRouter do
  @moduledoc false

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AshCompliance.Web.TestLayout, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", AshCompliance.Web do
    pipe_through(:browser)

    live("/editor", RulesetEditorWrapper, :index, as: :ruleset_editor)

    live("/orgs/:organization_id/editor", RulesetEditorWrapper, :organization,
      as: :org_ruleset_editor
    )

    live("/rule-sets/:revision/editor", RulesetEditorWrapper, :revision,
      as: :revision_ruleset_editor
    )
  end
end

defmodule AshCompliance.Web.TestEndpoint do
  @moduledoc false

  # Configuration lives in `config/test.exs`, NOT in a compile-time
  # `Application.put_env` in this module body — that trick only runs on a
  # fresh compilation and is silently absent from cached beams, which is
  # ash_decisions' test endpoint note verbatim and it applies here too.
  use Phoenix.Endpoint, otp_app: :ash_compliance

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.RequestId)

  plug(Plug.Session,
    store: :cookie,
    key: "_ash_compliance_test_session",
    signing_salt: String.duplicate("c", 16),
    encrypt: false
  )

  plug(AshCompliance.Web.TestRouter)
end

defmodule AshCompliance.Web.ErrorView do
  @moduledoc false
  def render(template, _assigns), do: "error: #{template}"
end
