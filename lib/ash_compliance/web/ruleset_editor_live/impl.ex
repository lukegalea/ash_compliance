# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Web.RulesetEditorLive.Impl do
  @moduledoc false

  # The server logic behind the ruleset editor LiveView that
  # `AshCompliance.Web.RulesetEditorLive` injects. It lives here rather than
  # inside the `use` macro's quote so the quote stays readable callbacks and
  # the logic stays ordinary functions — the same arrangement
  # `AshDecisions.Web.EditorLive.Impl` uses.
  #
  # The editor's state is a plain map of strings: what the operator sees is
  # what the state holds. The Ir encode path is the only way state becomes
  # `rules_json`, and decode is the only way a revision becomes editor state,
  # so the editor can never store what the engine cannot read back.

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias AshCompliance.Compiler.Layer
  alias AshRules.Ir
  alias AshRules.Ir.Bundle
  alias AshRules.Ir.OutcomeDeclaration
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Var

  @combining_options AshRules.Combining.algorithms() |> Enum.map(&to_string/1)
  @layer_options Layer.revision_layers() |> Enum.map(&to_string/1)
  @type_options AshRules.Ir.Fact.types() |> Enum.map(&to_string/1)
  @missing_options ["false", "unknown", "no_fact"]
  @severity_options AshRules.Ir.Rule.severities() |> Enum.map(&to_string/1)
  @outcome_options OutcomeDeclaration.allowed() |> Enum.map(&to_string/1)

  # ── Mount & params ──────────────────────────────────────────────────────────

  def mount(socket) do
    assign(socket,
      domain: nil,
      organization_id: nil,
      actor: nil,
      editor: nil,
      revisions: [],
      active_bundle: nil,
      compiled_bundle: nil,
      diagnostics: []
    )
  end

  @doc """
  Resolves the domain, organization and actor, loads the rule-set list and the
  active bundle, and hydrates the editor from the route's revision when there
  is one.

  Hydration is how an operator continues from what is live: selecting — or
  routing to — an active revision edits that rule set, and the next save
  drafts a *new* revision from it, never over what is already live.
  """
  def handle_params(params, socket, domain, organization, actor_mfa, compile_time_revision) do
    socket =
      assign(socket,
        domain: domain,
        organization_id: resolve_organization(params, organization, socket),
        actor: resolve_actor(actor_mfa, socket),
        diagnostics: [],
        compiled_bundle: nil
      )

    socket = refresh(socket)

    case params["revision"] || compile_time_revision do
      nil -> assign(socket, editor: blank_editor())
      revision_id -> hydrate(socket, revision_id)
    end
  end

  defp resolve_organization(params, organization, socket) do
    params["organization_id"] || params["org"] || resolve_option(organization, socket) ||
      raise """
      ash_compliance: the ruleset editor has no organization.

      The editor scopes everything it reads and writes by organization_id, so
      the host must supply it. Pass one at compile time — an MFA called as
      `module.function(args ++ [socket])`, or a literal:

          use AshCompliance.Web.RulesetEditorLive,
            domain: AshCompliance.Domain,
            organization: {MyApp.Org, :current_organization_id, []}

      or put it in the route:

          live "/orgs/:organization_id/compliance", MyAppWeb.Compliance.EditorLive
      """
  end

  defp resolve_option({module, function, args}, socket),
    do: apply(module, function, args ++ [socket])

  defp resolve_option(value, _socket), do: value

  defp resolve_actor({module, function, args}, socket),
    do: apply(module, function, args ++ [socket])

  defp resolve_actor(_other, _socket), do: nil

  # Host-facing entry point: the operator's actor threads through every call,
  # so a host's policies apply to everything the editor does. A host with no
  # policies gets authorized-but-unrestricted, per the domain's contract.
  defp call_opts(socket), do: [actor: socket.assigns.actor, authorize?: true]

  # ── The rule-set list ───────────────────────────────────────────────────────

  @doc "Reloads the revision list and the active bundle for the organization."
  def refresh(socket) do
    domain = socket.assigns.domain
    organization_id = socket.assigns.organization_id
    opts = call_opts(socket)

    revisions =
      case apply(domain, :rule_set_revisions_for_organization, [organization_id, opts]) do
        {:ok, revisions} -> revisions
        revisions when is_list(revisions) -> revisions
      end

    {:ok, active_bundle} = apply(domain, :active_policy_bundle, [organization_id, opts])

    assign(socket, revisions: revisions, active_bundle: active_bundle)
  end

  # ── Hydration: a revision becomes editor state ──────────────────────────────

  @doc "Loads a revision and decodes its rules_json into the editor."
  def hydrate(socket, revision_id) do
    case fetch_revision(socket, revision_id) do
      {:ok, revision} ->
        case Ir.decode(revision.rules_json) do
          {:ok, bundle} ->
            socket
            |> assign(editor: editor_from_bundle(revision, bundle))
            |> assign(diagnostics: [])

          {:error, errors} ->
            socket
            |> assign(editor: blank_editor())
            |> assign(diagnostics: List.wrap(errors))
            |> put_flash(:error, "rule set #{revision.name} does not decode")
        end

      {:error, _} ->
        put_flash(socket, :error, "no such rule set revision")
    end
  end

  defp fetch_revision(socket, revision_id) do
    apply(socket.assigns.domain, :get_rule_set_revision_by_id, [revision_id, call_opts(socket)])
  end

  def editor_from_bundle(revision, bundle) do
    %{
      revision_id: revision.id,
      status: revision.status,
      name: revision.name,
      revision: revision.revision,
      layer: to_string(revision.layer),
      combining: to_string(revision.combining),
      source_module: revision.source_module || "",
      facts: Enum.map(bundle.fact_schema.facts, &fact_to_state/1),
      rules: Enum.map(bundle.rules, &rule_to_state/1)
    }
  end

  defp fact_to_state(fact) do
    %{
      name: Atom.to_string(fact.name),
      type: to_string(fact.type),
      one_of: (fact.one_of && Enum.map_join(fact.one_of, ", ", &Atom.to_string/1)) || "",
      missing: missing_to_string(fact.missing),
      description: fact.description || ""
    }
  end

  defp missing_to_string(false), do: "false"
  defp missing_to_string(missing), do: Atom.to_string(missing)

  defp rule_to_state(rule) do
    %{
      name: rule.name,
      id: rule.id,
      severity: (rule.severity && Atom.to_string(rule.severity)) || "medium",
      outcome: (rule.outcome && Atom.to_string(rule.outcome.outcome)) || "noncompliant",
      gap: (rule.outcome && rule.outcome.gap) || "",
      message: rule.message || "",
      requires: Enum.map(rule.applicability, &predicate_to_state/1),
      fails: Enum.map(rule.failure_conditions, &predicate_to_state/1)
    }
  end

  defp predicate_to_state(predicate) do
    %{
      subject: term_to_state(predicate.subject),
      fact: Atom.to_string(predicate.name),
      value: term_to_state(predicate.value)
    }
  end

  defp term_to_state(%Var{name: name}), do: "$" <> Atom.to_string(name)
  defp term_to_state(nil), do: ""
  defp term_to_state(atom) when is_atom(atom) and not is_boolean(atom), do: Atom.to_string(atom)

  defp term_to_state(%mod{} = value) when mod in [Date, DateTime],
    do: mod.to_iso8601(value)

  defp term_to_state(value) when is_binary(value), do: value
  defp term_to_state(value), do: to_string(value)

  # ── Editor buffer: the phx-change and row operations ────────────────────────

  @revision_fields ["name", "revision", "layer", "combining", "source_module"]

  @doc "Applies one edited field, addressed by the form's `_target` path."
  def change(socket, %{"_target" => target} = params) when is_list(target) do
    value = get_in(params, target) || ""

    case apply_change(socket.assigns.editor, target, value) do
      {:ok, editor} -> assign(socket, :editor, editor)
      :error -> socket
    end
  end

  def change(socket, _params), do: socket

  def apply_change(editor, ["facts", index, field], value)
      when field in ["name", "type", "one_of", "missing", "description"] do
    {:ok, update_in_state(editor, :facts, index, field, value)}
  end

  def apply_change(editor, ["rules", index, field], value)
      when field in ["name", "id", "severity", "outcome", "gap", "message"] do
    {:ok, update_in_state(editor, :rules, index, field, value)}
  end

  def apply_change(editor, ["rules", index, section, triple_index, field], value)
      when section in ["requires", "fails"] and field in ["subject", "fact", "value"] do
    {:ok,
     editor
     |> Map.update!(
       :rules,
       &update_list_at(&1, index, fn rule ->
         update_in_state(rule, section_key(section), triple_index, field, value)
       end)
     )}
  end

  def apply_change(editor, [field], value) when field in @revision_fields do
    {:ok, Map.put(editor, String.to_existing_atom(field), value)}
  end

  def apply_change(_editor, _path, _value), do: :error

  defp section_key("requires"), do: :requires
  defp section_key("fails"), do: :fails

  defp update_in_state(state, key, index, field, value) do
    Map.update!(state, key, fn rows ->
      update_list_at(rows, index, &Map.put(&1, String.to_existing_atom(field), value))
    end)
  end

  defp update_list_at(list, index, fun) do
    case Integer.parse(index) do
      {position, ""} when position >= 0 and position < length(list) ->
        List.update_at(list, position, fun)

      _ ->
        list
    end
  end

  @doc "A blank fact row, so add has something to add and the form has a base."
  def blank_fact do
    %{name: "", type: "atom", one_of: "", missing: "false", description: ""}
  end

  def blank_triple do
    %{subject: "", fact: "", value: ""}
  end

  def blank_rule do
    %{
      name: "",
      id: "",
      severity: "medium",
      outcome: "noncompliant",
      gap: "",
      message: "",
      requires: [blank_triple()],
      fails: [blank_triple()]
    }
  end

  def blank_editor do
    %{
      revision_id: nil,
      status: :new,
      name: "",
      revision: "1",
      layer: "tenant_supplement",
      combining: "deny_overrides",
      source_module: "",
      facts: [blank_fact()],
      rules: [blank_rule()]
    }
  end

  def add_fact(editor), do: %{editor | facts: editor.facts ++ [blank_fact()]}

  def remove_fact(editor, index), do: %{editor | facts: drop_at(editor.facts, index)}

  def add_rule(editor), do: %{editor | rules: editor.rules ++ [blank_rule()]}

  def remove_rule(editor, index), do: %{editor | rules: drop_at(editor.rules, index)}

  def add_triple(editor, rule_index, section),
    do: %{editor | rules: update_list_at(editor.rules, rule_index, &add_triple_to(&1, section))}

  def remove_triple(editor, rule_index, section, triple_index) do
    %{
      editor
      | rules:
          update_list_at(editor.rules, rule_index, &remove_triple_from(&1, section, triple_index))
    }
  end

  defp add_triple_to(rule, section),
    do: Map.update!(rule, section_key(section), &(&1 ++ [blank_triple()]))

  defp remove_triple_from(rule, section, index) do
    Map.update!(rule, section_key(section), fn triples ->
      case Integer.parse(index) do
        {position, ""} when position >= 0 and position < length(triples) ->
          List.delete_at(triples, position)

        _ ->
          triples
      end
    end)
  end

  defp drop_at(list, index) do
    case Integer.parse(index) do
      {position, ""} when position >= 0 and position < length(list) ->
        List.delete_at(list, position)

      _ ->
        list
    end
  end

  # ── State ⇄ JSON: what the save form carries ────────────────────────────────

  @doc "The editor state as JSON, for the hidden save-form input."
  def state_json(editor), do: Jason.encode!(to_params(editor))

  def to_params(editor) do
    %{
      "revision_id" => editor.revision_id,
      "status" => editor.status && to_string(editor.status),
      "name" => editor.name,
      "revision" => editor.revision,
      "layer" => editor.layer,
      "combining" => editor.combining,
      "source_module" => editor.source_module,
      "facts" => Enum.map(editor.facts, &stringify/1),
      "rules" => Enum.map(editor.rules, &stringify/1)
    }
  end

  defp stringify(map) do
    Map.new(map, fn
      {key, values} when is_list(values) ->
        {Atom.to_string(key), Enum.map(values, &stringify/1)}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end

  @doc "Accepts the string-keyed JSON the save form carries, or already-atom state."
  def from_params(params) when is_map(params) do
    %{
      revision_id: params["revision_id"],
      status: status_from_params(params["status"]),
      name: params["name"] || "",
      revision: params["revision"] || "1",
      layer: params["layer"] || "tenant_supplement",
      combining: params["combining"] || "deny_overrides",
      source_module: params["source_module"] || "",
      facts: Enum.map(List.wrap(params["facts"] || []), &fact_from_params/1),
      rules: Enum.map(List.wrap(params["rules"] || []), &rule_from_params/1)
    }
  end

  defp status_from_params(nil), do: :new
  defp status_from_params("new"), do: :new
  defp status_from_params(status), do: existing_atom(status, :new)

  defp fact_from_params(fact) do
    %{
      name: fact["name"] || "",
      type: fact["type"] || "atom",
      one_of: fact["one_of"] || "",
      missing: fact["missing"] || "false",
      description: fact["description"] || ""
    }
  end

  defp rule_from_params(rule) do
    %{
      name: rule["name"] || "",
      id: rule["id"] || "",
      severity: rule["severity"] || "medium",
      outcome: rule["outcome"] || "noncompliant",
      gap: rule["gap"] || "",
      message: rule["message"] || "",
      requires: Enum.map(List.wrap(rule["requires"] || []), &triple_from_params/1),
      fails: Enum.map(List.wrap(rule["fails"] || []), &triple_from_params/1)
    }
  end

  defp triple_from_params(triple) do
    %{
      subject: triple["subject"] || "",
      fact: triple["fact"] || "",
      value: triple["value"] || ""
    }
  end

  # ── State → Ir.Bundle ───────────────────────────────────────────────────────

  @doc """
  Builds the `AshRules.Ir.Bundle` the editor state describes.

  Enum-typed fields that do not resolve are build refusals rather than silent
  defaults — a bad combining algorithm must not quietly become
  `deny_overrides`. Everything else (unknown predicates, values that do not
  type-check, missing metadata) is left for the engine's verifiers, whose
  diagnostics the editor surfaces verbatim.
  """
  def build_bundle(editor) do
    with :ok <- check_combining(editor.combining),
         {:ok, facts} <- build_facts(editor.facts) do
      schema = AshRules.Ir.FactSchema.new(facts)
      types = Map.new(facts, fn fact -> {fact.name, fact.type} end)
      rules = build_rules(editor.rules, types)

      {:ok,
       Bundle.new(rules, schema, combining: existing_atom(editor.combining, :deny_overrides))}
    end
  end

  defp check_combining(combining) when combining in @combining_options, do: :ok

  defp check_combining(combining) do
    {:error, ["combining #{inspect(combining)} is not one of #{inspect(@combining_options)}"]}
  end

  defp build_facts(fact_states) do
    {facts, errors} =
      fact_states
      |> Enum.map(&Map.put(&1, :name, String.trim(&1.name)))
      |> Enum.reject(&blank?(&1.name))
      |> Enum.map_reduce([], fn fact, errors ->
        type = existing_atom(fact.type, nil)
        missing = missing_value(fact.missing)

        cond do
          type == nil or type not in AshRules.Ir.Fact.types() ->
            {nil,
             errors ++
               [
                 "fact #{fact.name}: type #{inspect(fact.type)} is not one of #{inspect(@type_options)}"
               ]}

          missing == :bad_missing ->
            {nil,
             errors ++
               [
                 "fact #{fact.name}: missing semantics #{inspect(fact.missing)} is not one of #{inspect(@missing_options)}"
               ]}

          true ->
            {AshRules.Ir.Fact.new(
               String.to_atom(fact.name),
               type,
               one_of: one_of_values(fact.one_of),
               missing: missing,
               description: blank_to_nil(fact.description)
             ), errors}
        end
      end)

    facts = Enum.reject(facts, &is_nil/1)

    if errors == [] do
      {:ok, facts}
    else
      {:error, errors}
    end
  end

  defp one_of_values("") do
    nil
  end

  defp one_of_values(one_of) do
    one_of
    |> String.split(",", trim: true)
    |> Enum.map(&(String.trim(&1) |> String.to_atom()))
  end

  defp missing_value("false"), do: false
  defp missing_value("unknown"), do: :unknown
  defp missing_value("no_fact"), do: :no_fact
  defp missing_value(_), do: :bad_missing

  defp build_rules(rule_states, types) do
    rule_states
    |> Enum.reject(&blank?(&1.id))
    |> Enum.map(fn rule ->
      AshRules.Ir.Rule.new(
        id: String.trim(rule.id),
        name: blank_to_nil(rule.name) || String.trim(rule.id),
        severity: existing_atom(rule.severity, nil),
        applicability: build_predicates(rule.requires, :has, types),
        failure_conditions: build_predicates(rule.fails, :neg, types),
        outcome:
          OutcomeDeclaration.new(
            outcome_value(rule.outcome),
            blank_to_nil(rule.gap)
          ),
        message: blank_to_nil(rule.message)
      )
    end)
  end

  defp outcome_value(outcome) when outcome in @outcome_options,
    do: String.to_existing_atom(outcome)

  defp outcome_value(_outcome), do: :noncompliant

  defp build_predicates(triples, op, types) do
    triples
    |> Enum.reject(&blank?(&1.fact))
    |> Enum.map(fn triple ->
      Predicate.new(
        op,
        subject_value(triple.subject),
        String.to_atom(String.trim(triple.fact)),
        typed_value(triple.value, types[String.to_atom(String.trim(triple.fact))])
      )
    end)
  end

  # A `$name` subject or value is a variable reference, bound by an earlier
  # has clause; anything else is the literal text.
  defp subject_value("$" <> name), do: Var.new(String.to_atom(name))
  defp subject_value(value), do: value

  defp typed_value("$" <> name, _type), do: Var.new(String.to_atom(name))

  defp typed_value(text, nil), do: String.trim(text)

  defp typed_value(text, type) do
    text = String.trim(text)

    case type do
      :atom -> String.to_atom(text)
      :boolean -> boolean_value(text)
      :integer -> integer_value(text)
      :float -> float_value(text)
      :date -> date_value(text)
      :utc_datetime -> datetime_value(text)
      _ -> text
    end
  end

  defp boolean_value("true"), do: true
  defp boolean_value("false"), do: false
  defp boolean_value(other), do: other

  defp integer_value(text) do
    case Integer.parse(text) do
      {value, ""} -> value
      _ -> text
    end
  end

  defp float_value(text) do
    case Float.parse(text) do
      {value, ""} -> value
      _ -> text
    end
  end

  defp date_value(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> date
      _ -> text
    end
  end

  defp datetime_value(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> datetime
      _ -> text
    end
  end

  # ── Toolbar: draft → validate → approve → activate → bundles ────────────────

  @doc """
  Drafts a rule set revision from the editor state.

  The state serializes through the Ir encode path, and the encoded JSON must
  decode — the engine's verifiers run on the way in — before anything is
  stored. Diagnostics render inline; nothing partial is persisted.
  """
  def save(socket, state_params) do
    editor = from_params(state_params)
    {editor, revision_string} = resolve_revision_string(socket, editor)

    with {:ok, bundle} <- build_bundle(editor) do
      json = Ir.encode!(bundle)

      case Ir.decode(json) do
        {:ok, _} -> draft_revision(socket, editor, revision_string, bundle, json)
        {:error, errors} -> refuse(socket, errors, "the rule set does not verify")
      end
    end
  end

  @doc "Like `save/2`, for the JSON the save form carries."
  def save_json(socket, json) do
    case Jason.decode(json) do
      {:ok, params} -> save(socket, params)
      {:error, _} -> refuse(socket, ["the editor state is not valid JSON"], "nothing was saved")
    end
  end

  # Revisions are immutable: saving from an existing revision drafts the next
  # one. An operator-edited revision string wins over the bump.
  defp resolve_revision_string(socket, editor) do
    case editor.revision_id && fetch_revision(socket, editor.revision_id) do
      {:ok, revision} when editor.revision == revision.revision ->
        {editor, bump_revision(revision.revision)}

      {:ok, _revision} ->
        {editor, editor.revision}

      _ ->
        {editor, editor.revision}
    end
  end

  defp bump_revision(revision) do
    case Integer.parse(revision) do
      {number, ""} -> Integer.to_string(number + 1)
      _ -> revision <> ".1"
    end
  end

  defp draft_revision(socket, editor, revision_string, bundle, json) do
    attrs = %{
      organization_id: socket.assigns.organization_id,
      name: String.trim(editor.name),
      revision: revision_string,
      layer: existing_atom(editor.layer, nil),
      combining: String.to_existing_atom(editor.combining),
      source_module: blank_to_nil(editor.source_module),
      rules_json: json,
      content_hash: bundle.content_hash
    }

    case apply(socket.assigns.domain, :draft_rule_set_revision, [attrs, call_opts(socket)]) do
      {:ok, revision} ->
        socket
        |> assign(
          editor: %{
            editor
            | revision_id: revision.id,
              status: :draft,
              revision: revision.revision
          }
        )
        |> assign(diagnostics: [])
        |> refresh()
        |> put_flash(:info, "drafted #{revision.name} v#{revision.revision}")

      {:error, error} ->
        refuse(socket, error_messages(error), "the revision was refused")
    end
  end

  @doc """
  Runs the engine's verifiers over the selected revision's stored JSON and
  surfaces the diagnostics inline; a clean decode moves the revision to
  validated through the domain action.
  """
  def validate(socket) do
    with_revision(socket, fn revision ->
      case Ir.decode(revision.rules_json) do
        {:ok, _} ->
          transition(socket, revision, :validate_rule_set_revision, "validated")

        {:error, errors} ->
          refuse(socket, errors, "#{revision.name} v#{revision.revision} does not verify")
      end
    end)
  end

  def approve(socket) do
    with_revision(socket, fn revision ->
      transition(socket, revision, :approve_rule_set_revision, "approved")
    end)
  end

  def activate(socket) do
    with_revision(socket, fn revision ->
      transition(socket, revision, :activate_rule_set_revision, "activated")
    end)
  end

  defp with_revision(socket, fun) do
    case socket.assigns.editor && socket.assigns.editor.revision_id do
      nil ->
        put_flash(socket, :error, "select a rule set revision first")

      revision_id ->
        case fetch_revision(socket, revision_id) do
          {:ok, revision} -> fun.(revision)
          {:error, _} -> put_flash(socket, :error, "no such rule set revision")
        end
    end
  end

  defp transition(socket, revision, action, past_tense) do
    case apply(socket.assigns.domain, action, [revision, call_opts(socket)]) do
      {:ok, updated} ->
        editor =
          case socket.assigns.editor do
            %{revision_id: id} when id == updated.id ->
              %{socket.assigns.editor | status: updated.status}

            other ->
              other
          end

        socket
        |> assign(editor: editor)
        |> assign(diagnostics: [])
        |> refresh()
        |> put_flash(:info, "#{updated.name} v#{updated.revision} #{past_tense}")

      {:error, error} ->
        refuse(
          socket,
          error_messages(error),
          "#{revision.name} v#{revision.revision} was not #{past_tense}"
        )
    end
  end

  @doc "Compiles the organization's active layers into a PolicyBundle."
  def compile_bundle(socket, label) do
    attrs = %{organization_id: socket.assigns.organization_id, label: blank_to_nil(label)}

    case apply(socket.assigns.domain, :compile_policy_bundle, [attrs, call_opts(socket)]) do
      {:ok, bundle} ->
        socket
        |> assign(compiled_bundle: bundle)
        |> assign(diagnostics: [])
        |> refresh()
        |> put_flash(:info, "compiled bundle #{short_hash(bundle.content_hash)}")

      {:error, error} ->
        refuse(socket, error_messages(error), "the compile was refused")
    end
  end

  @doc """
  Validate-before-activate lives in the domain action; the editor picks the
  bundle to run it on — the one this session compiled, else the
  organization's latest.
  """
  def activate_bundle(socket) do
    bundle = socket.assigns.compiled_bundle || latest_bundle(socket)

    case bundle do
      nil ->
        put_flash(socket, :error, "nothing to activate — compile a bundle first")

      bundle ->
        case apply(socket.assigns.domain, :activate_policy_bundle, [bundle, call_opts(socket)]) do
          {:ok, bundle} ->
            socket
            |> assign(compiled_bundle: nil)
            |> assign(diagnostics: [])
            |> refresh()
            |> put_flash(:info, "bundle #{short_hash(bundle.content_hash)} active")

          {:error, error} ->
            refuse(socket, error_messages(error), "the bundle was not activated")
        end
    end
  end

  defp latest_bundle(socket) do
    case apply(socket.assigns.domain, :latest_policy_bundle, [
           socket.assigns.organization_id,
           call_opts(socket)
         ]) do
      {:ok, bundle} -> bundle
      {:error, _} -> nil
    end
  end

  defp refuse(socket, messages, summary) do
    socket
    |> assign(diagnostics: List.wrap(messages))
    |> put_flash(:error, summary)
  end

  defp error_messages(errors) when is_list(errors), do: Enum.flat_map(errors, &error_messages/1)
  defp error_messages(error) when is_binary(error), do: [error]

  defp error_messages(error) do
    [Exception.message(error)]
  rescue
    _ -> [inspect(error)]
  end

  # ── Select options for the rendered form ────────────────────────────────────

  def combining_options, do: @combining_options
  def layer_options, do: @layer_options
  def type_options, do: @type_options
  def missing_options, do: @missing_options
  def severity_options, do: @severity_options
  def outcome_options, do: @outcome_options

  @doc "The first twelve hash characters — enough to eyeball two bundles apart."
  def short_hash(nil), do: ""
  def short_hash(hash), do: String.slice(hash, 0, 12)

  defp existing_atom(value, fallback) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> fallback
  end

  defp existing_atom(value, _fallback), do: value

  defp blank?(value), do: value in [nil, ""]
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: String.trim(value))
end
