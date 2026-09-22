# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Web.RulesetEditorLive do
  @moduledoc """
  The ruleset editor LiveView: a structured form over facts and rules that
  drives the `RuleSetRevision` → `PolicyBundle` lifecycle this package owns.

      defmodule MyAppWeb.Compliance.RulesetEditorLive do
        use AshCompliance.Web.RulesetEditorLive,
          domain: AshCompliance.Domain,
          organization: {MyApp.Org, :current_organization_id, []},
          actor: {MyAppWeb.Helpers, :current_actor, []}
      end

  ## Options

    * `:domain` — **required**. The host Ash domain holding the compliance
      resources and exposing their code interfaces — `AshCompliance.Domain`
      itself, or a host domain that declares the same interfaces.
    * `:organization` — **required in practice**. The organization_id every
      read and write is scoped by: an `{module, function, args}` MFA called
      as `module.function(args ++ [socket])`, or a literal value. A route
      `:organization_id` (or `:org`) param wins over the option; supplying
      neither raises at mount with a message saying so.
    * `:actor` — optional `{module, function, args}`, called as
      `module.function(args ++ [socket])`. The operator's actor threads
      through every call with `authorize?: true`, so the host's policies
      apply to everything the editor does.
    * `:revision` — optional rule set revision id to open, for hosts that
      route to one revision; the route's `:revision` param wins.

  ## Structured form, not DSL text

  Facts and rules are edited as rows — a fact is {name, type, one_of values,
  missing semantics, description}; a rule is {name, id, severity,
  when_requires triples, fails_when triples, outcome, gap text} — and the
  state serializes to `rules_json` through `AshRules.Ir.encode!` on every
  save. There is no raw-DSL text field anywhere: what the operator cannot
  say in the form, the engine cannot be handed. Opening an existing revision
  hydrates the editor through `AshRules.Ir.decode`, so the editor always
  shows exactly what the engine would read. Subjects and values are text;
  a `$name` subject or value in a triple is a variable reference, bound by
  an earlier `has` clause.

  ## The toolbar is the lifecycle, 1:1

  Draft → Validate → Approve → Activate → Compile bundle → Activate bundle,
  each button backed by the domain's own code interface — the editor
  implements none of the lifecycle itself. Validate decodes the selected
  revision's stored JSON first and renders the verifier's diagnostics inline;
  a rule set that does not verify stays draft. Compile runs the fixed layer
  resolution the compiler owns and refuses what the compiler refuses.

  ## Revisions are immutable, and so is the editor's save

  Saving always drafts a *new* revision. Editing continues from whatever was
  selected — including an active revision — and the next save bumps the
  revision string unless the operator typed one. Nothing already live is
  ever overwritten.

  ## Testability

  Every lifecycle button is a hidden `<form>` with the state or revision id
  in a hidden input, so a test drives the whole lifecycle with
  `render_submit/2` — no browser. The same handlers serve the phx-change and
  phx-click events the real editing flow produces. This is the arrangement
  `AshDecisions.Web.EditorLive` uses, for the same reason: an editor whose
  only path to the database runs through JavaScript is an editor with no
  server-side tests.

  ## Events

  Client → server: `field` (form change), `add_fact` / `remove_fact`,
  `add_rule` / `remove_rule`, `add_requires` / `remove_requires`,
  `add_fails` / `remove_fails`, `new_draft`, `select`, `draft`, `validate`,
  `approve`, `activate`, `compile_bundle`, `activate_bundle`.
  """

  use Phoenix.Component

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    organization = Keyword.get(opts, :organization)
    revision = Keyword.get(opts, :revision)
    # NOT `Macro.escape/1`. These options arrive already as AST; escaping AST
    # stores the alias unexpanded and it reaches `apply/3` as a three-tuple
    # rather than a module, which fails as `ArgumentError: 2nd argument: not an
    # atom` at the first call. ash_decisions' LiveViews carry the same note.
    actor_mfa = Keyword.get(opts, :actor, nil)

    quote do
      use Phoenix.LiveView

      alias AshCompliance.Web.RulesetEditorLive

      @ash_compliance_domain unquote(domain)
      @ash_compliance_organization unquote(organization)
      @ash_compliance_revision unquote(revision)
      @ash_compliance_actor_mfa unquote(actor_mfa)

      # ── Mount & params ──────────────────────────────────────────────────

      @impl true
      def mount(_params, _session, socket) do
        {:ok, RulesetEditorLive.Impl.mount(socket)}
      end

      @impl true
      def handle_params(params, _uri, socket) do
        {:noreply,
         RulesetEditorLive.Impl.handle_params(
           params,
           socket,
           @ash_compliance_domain,
           @ash_compliance_organization,
           @ash_compliance_actor_mfa,
           @ash_compliance_revision
         )}
      end

      # ── Editor buffer: form changes and row operations ──────────────────

      @impl true
      def handle_event("field", params, socket) do
        {:noreply, RulesetEditorLive.Impl.change(socket, params)}
      end

      @impl true
      def handle_event("add_fact", _params, socket) do
        {:noreply,
         Phoenix.Component.assign(
           socket,
           :editor,
           RulesetEditorLive.Impl.add_fact(socket.assigns.editor)
         )}
      end

      @impl true
      def handle_event("remove_fact", %{"index" => index}, socket) do
        {:noreply,
         Phoenix.Component.assign(
           socket,
           :editor,
           RulesetEditorLive.Impl.remove_fact(socket.assigns.editor, index)
         )}
      end

      @impl true
      def handle_event("add_rule", _params, socket) do
        {:noreply,
         Phoenix.Component.assign(
           socket,
           :editor,
           RulesetEditorLive.Impl.add_rule(socket.assigns.editor)
         )}
      end

      @impl true
      def handle_event("remove_rule", %{"index" => index}, socket) do
        {:noreply,
         Phoenix.Component.assign(
           socket,
           :editor,
           RulesetEditorLive.Impl.remove_rule(socket.assigns.editor, index)
         )}
      end

      @impl true
      def handle_event("add_requires", %{"rule" => rule}, socket) do
        {:noreply,
         Phoenix.Component.assign(
           socket,
           :editor,
           RulesetEditorLive.Impl.add_triple(socket.assigns.editor, rule, "requires")
         )}
      end

      @impl true
      def handle_event("remove_requires", %{"rule" => rule, "index" => index}, socket) do
        {:noreply,
         Phoenix.Component.assign(
           socket,
           :editor,
           RulesetEditorLive.Impl.remove_triple(socket.assigns.editor, rule, "requires", index)
         )}
      end

      @impl true
      def handle_event("add_fails", %{"rule" => rule}, socket) do
        {:noreply,
         Phoenix.Component.assign(
           socket,
           :editor,
           RulesetEditorLive.Impl.add_triple(socket.assigns.editor, rule, "fails")
         )}
      end

      @impl true
      def handle_event("remove_fails", %{"rule" => rule, "index" => index}, socket) do
        {:noreply,
         Phoenix.Component.assign(
           socket,
           :editor,
           RulesetEditorLive.Impl.remove_triple(socket.assigns.editor, rule, "fails", index)
         )}
      end

      @impl true
      def handle_event("new_draft", _params, socket) do
        {:noreply,
         Phoenix.Component.assign(socket, :editor, RulesetEditorLive.Impl.blank_editor())}
      end

      @impl true
      def handle_event("select", %{"id" => id}, socket) do
        {:noreply, RulesetEditorLive.Impl.hydrate(socket, id)}
      end

      # ── The toolbar: the lifecycle, one form per step ────────────────────

      @impl true
      def handle_event("draft", %{"state" => state}, socket) do
        {:noreply, RulesetEditorLive.Impl.save_json(socket, state)}
      end

      def handle_event("draft", _params, socket) do
        {:noreply,
         RulesetEditorLive.Impl.save(
           socket,
           RulesetEditorLive.Impl.to_params(socket.assigns.editor)
         )}
      end

      @impl true
      def handle_event("validate", _params, socket) do
        {:noreply, RulesetEditorLive.Impl.validate(socket)}
      end

      @impl true
      def handle_event("approve", _params, socket) do
        {:noreply, RulesetEditorLive.Impl.approve(socket)}
      end

      @impl true
      def handle_event("activate", _params, socket) do
        {:noreply, RulesetEditorLive.Impl.activate(socket)}
      end

      @impl true
      def handle_event("compile_bundle", %{"label" => label}, socket) do
        {:noreply, RulesetEditorLive.Impl.compile_bundle(socket, label)}
      end

      def handle_event("compile_bundle", _params, socket) do
        {:noreply, RulesetEditorLive.Impl.compile_bundle(socket, nil)}
      end

      @impl true
      def handle_event("activate_bundle", _params, socket) do
        {:noreply, RulesetEditorLive.Impl.activate_bundle(socket)}
      end

      @impl true
      def render(assigns), do: RulesetEditorLive.__render__(assigns)
    end
  end

  # ── Rendering ─────────────────────────────────────────────────────────────

  # Plain semantic HTML on purpose: no framework classes, no stylesheet. The
  # host owns the design system — ids and data-* attributes are the styling
  # contract.

  @doc false
  def __render__(assigns) do
    ~H"""
    <div id="ruleset-editor-live" data-organization-id={@organization_id}>
      <header id="ruleset-editor-header">
        <h1>Rule sets</h1>
        <p id="active-bundle" :if={@active_bundle} data-content-hash={@active_bundle.content_hash}>
          active bundle <%= AshCompliance.Web.RulesetEditorLive.Impl.short_hash(@active_bundle.content_hash) %>
        </p>
        <p id="active-bundle" :if={@active_bundle == nil}>no active bundle</p>
      </header>

      <table id="rule-set-list">
        <thead>
          <tr>
            <th>Name</th>
            <th>Revision</th>
            <th>Layer</th>
            <th>Combining</th>
            <th>Status</th>
            <th>Content hash</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={revision <- @revisions} data-status={revision.status} data-revision-id={revision.id}>
            <td>{revision.name}</td>
            <td>{revision.revision}</td>
            <td>{revision.layer}</td>
            <td>{revision.combining}</td>
            <td><span data-status={revision.status}>{revision.status}</span></td>
            <td data-content-hash={revision.content_hash}>
              <%= AshCompliance.Web.RulesetEditorLive.Impl.short_hash(revision.content_hash) %>
            </td>
            <td>
              <button type="button" phx-click="select" phx-value-id={revision.id} data-action="select">
                Edit
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <section id="rule-set-editor" :if={@editor} data-revision-id={@editor.revision_id} data-status={@editor.status}>
        <h2>
          <%= if @editor.name == "", do: "New rule set", else: @editor.name %>
          <%= if @editor.revision_id, do: "v#{@editor.revision}" %>
        </h2>

        <%!-- The editing buffer. Every input reports through phx-change with
              its _target path; the buffer lives in assigns and the save form
              serializes it through the Ir encode path. --%>
        <form id="editor-buffer-form" phx-change="field">
          <fieldset id="revision-meta">
            <legend>Rule set</legend>
            <label>Name <input type="text" name="name" value={@editor.name} /></label>
            <label>Revision <input type="text" name="revision" value={@editor.revision} /></label>
            <label>
              Layer
              <select name="layer">
                <option :for={layer <- layer_options()} value={layer} selected={layer == @editor.layer}>
                  {layer}
                </option>
              </select>
            </label>
            <label>
              Combining
              <select name="combining">
                <option :for={combining <- combining_options()} value={combining} selected={combining == @editor.combining}>
                  {combining}
                </option>
              </select>
            </label>
            <label>Source module <input type="text" name="source_module" value={@editor.source_module} /></label>
          </fieldset>

          <table id="fact-editor">
            <caption>Facts</caption>
            <thead>
              <tr>
                <th>Name</th>
                <th>Type</th>
                <th>one_of (comma separated)</th>
                <th>Missing semantics</th>
                <th>Description</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{fact, i} <- Enum.with_index(@editor.facts)} data-fact-row={i}>
                <td><input type="text" name={"facts[#{i}][name]"} value={fact.name} /></td>
                <td>
                  <select name={"facts[#{i}][type]"}>
                    <option :for={type <- type_options()} value={type} selected={type == fact.type}>{type}</option>
                  </select>
                </td>
                <td><input type="text" name={"facts[#{i}][one_of]"} value={fact.one_of} /></td>
                <td>
                  <select name={"facts[#{i}][missing]"}>
                    <option :for={missing <- missing_options()} value={missing} selected={missing == fact.missing}>
                      {missing}
                    </option>
                  </select>
                </td>
                <td><input type="text" name={"facts[#{i}][description]"} value={fact.description} /></td>
                <td>
                  <button type="button" phx-click="remove_fact" phx-value-index={i} data-action="remove_fact">
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
          <button type="button" phx-click="add_fact" data-action="add_fact">Add fact</button>

          <section id="rule-editor">
            <h3>Rules</h3>
            <div :for={{rule, i} <- Enum.with_index(@editor.rules)} data-rule-row={i}>
              <fieldset>
                <legend>
                  Rule {i + 1}
                  <button type="button" phx-click="remove_rule" phx-value-index={i} data-action="remove_rule">
                    Remove rule
                  </button>
                </legend>

                <label>Name <input type="text" name={"rules[#{i}][name]"} value={rule.name} /></label>
                <label>Id <input type="text" name={"rules[#{i}][id]"} value={rule.id} /></label>
                <label>
                  Severity
                  <select name={"rules[#{i}][severity]"}>
                    <option :for={severity <- severity_options()} value={severity} selected={severity == rule.severity}>
                      {severity}
                    </option>
                  </select>
                </label>
                <label>
                  Outcome
                  <select name={"rules[#{i}][outcome]"}>
                    <option :for={outcome <- outcome_options()} value={outcome} selected={outcome == rule.outcome}>
                      {outcome}
                    </option>
                  </select>
                </label>
                <label>Gap <input type="text" name={"rules[#{i}][gap]"} value={rule.gap} /></label>
                <label>Message <input type="text" name={"rules[#{i}][message]"} value={rule.message} /></label>

                <table data-section="requires">
                  <caption>when_requires</caption>
                  <thead>
                    <tr>
                      <th>Subject ($name for a variable)</th>
                      <th>Fact</th>
                      <th>Value</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{triple, j} <- Enum.with_index(rule.requires)} data-triple-row={j}>
                      <td><input type="text" name={"rules[#{i}][requires][#{j}][subject]"} value={triple.subject} /></td>
                      <td><input type="text" name={"rules[#{i}][requires][#{j}][fact]"} value={triple.fact} /></td>
                      <td><input type="text" name={"rules[#{i}][requires][#{j}][value]"} value={triple.value} /></td>
                      <td>
                        <button
                          type="button"
                          phx-click="remove_requires"
                          phx-value-rule={i}
                          phx-value-index={j}
                          data-action="remove_requires"
                        >
                          Remove
                        </button>
                      </td>
                    </tr>
                  </tbody>
                </table>
                <button type="button" phx-click="add_requires" phx-value-rule={i} data-action="add_requires">
                  Add when_requires
                </button>

                <table data-section="fails">
                  <caption>fails_when</caption>
                  <thead>
                    <tr>
                      <th>Subject ($name for a variable)</th>
                      <th>Fact</th>
                      <th>Value</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{triple, j} <- Enum.with_index(rule.fails)} data-triple-row={j}>
                      <td><input type="text" name={"rules[#{i}][fails][#{j}][subject]"} value={triple.subject} /></td>
                      <td><input type="text" name={"rules[#{i}][fails][#{j}][fact]"} value={triple.fact} /></td>
                      <td><input type="text" name={"rules[#{i}][fails][#{j}][value]"} value={triple.value} /></td>
                      <td>
                        <button
                          type="button"
                          phx-click="remove_fails"
                          phx-value-rule={i}
                          phx-value-index={j}
                          data-action="remove_fails"
                        >
                          Remove
                        </button>
                      </td>
                    </tr>
                  </tbody>
                </table>
                <button type="button" phx-click="add_fails" phx-value-rule={i} data-action="add_fails">
                  Add fails_when
                </button>
              </fieldset>
            </div>
          </section>
          <button type="button" phx-click="add_rule" data-action="add_rule">Add rule</button>
          <button type="button" phx-click="new_draft" data-action="new_draft">New</button>
        </form>

        <%!-- The lifecycle. Hidden forms — the save form carries the serialized
              editor state, the rest carry the selected revision id — so the
              whole lifecycle is drivable with render_submit/2. --%>
        <div id="lifecycle-toolbar">
          <form id="draft-form" phx-submit="draft">
            <input type="hidden" name="state" value={state_json(@editor)} />
            <button type="submit" data-action="draft">Draft</button>
          </form>
          <form id="validate-form" phx-submit="validate">
            <input type="hidden" name="revision_id" value={@editor.revision_id} />
            <button type="submit" data-action="validate">Validate</button>
          </form>
          <form id="approve-form" phx-submit="approve">
            <input type="hidden" name="revision_id" value={@editor.revision_id} />
            <button type="submit" data-action="approve">Approve</button>
          </form>
          <form id="activate-form" phx-submit="activate">
            <input type="hidden" name="revision_id" value={@editor.revision_id} />
            <button type="submit" data-action="activate">Activate</button>
          </form>
          <form id="compile-form" phx-submit="compile_bundle">
            <input type="text" name="label" placeholder="Bundle label" />
            <button type="submit" data-action="compile">Compile bundle</button>
          </form>
          <form id="activate-bundle-form" phx-submit="activate_bundle">
            <button type="submit" data-action="activate_bundle">Activate bundle</button>
          </form>
        </div>
      </section>

      <%!-- Verifier diagnostics, shown rather than swallowed. A rule set that
            does not verify is the normal state of one being edited. --%>
      <ul :if={@diagnostics != []} id="ruleset-errors">
        <li :for={diagnostic <- @diagnostics}>{diagnostic}</li>
      </ul>
    </div>
    """
  end

  defp layer_options, do: AshCompliance.Web.RulesetEditorLive.Impl.layer_options()

  defp combining_options, do: AshCompliance.Web.RulesetEditorLive.Impl.combining_options()

  defp type_options, do: AshCompliance.Web.RulesetEditorLive.Impl.type_options()

  defp missing_options, do: AshCompliance.Web.RulesetEditorLive.Impl.missing_options()

  defp severity_options, do: AshCompliance.Web.RulesetEditorLive.Impl.severity_options()

  defp outcome_options, do: AshCompliance.Web.RulesetEditorLive.Impl.outcome_options()

  defp state_json(editor), do: AshCompliance.Web.RulesetEditorLive.Impl.state_json(editor)
end
