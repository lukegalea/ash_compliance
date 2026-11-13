# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources do
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
  # The quote is a whole resource, emitted onto the host's own base so the host's
  # policies govern it. A resource-length quote is the point.
  @moduledoc """
  The resource macros a host instantiates on its own resources.

  Each macro goes after the host's own `use Ash.Resource` line, so the resource keeps
  the host's domain, authorizers and policies. The package emits no policy: who may read
  the archive is the host's decision.

  ## `{:evidence_archive, opts}`

  Where `AshCompliance.Resources.EvidenceArtifact` rows go after the hot window. The
  columns are the hot table's own (`columns/0`) plus `archived_at`, so an archived
  artifact still hashes to its `hash`: `content` is kept. `method` is a string here, so
  an archived row still loads if the hot attribute's allowed values change.

  There is no create, update or destroy action. Rows arrive only through
  `AshCompliance.Ownership.Retention.archive/1`, which verifies each copy against the
  hot row before it deletes the hot row. A guard trigger refuses every `UPDATE`, and
  every `DELETE` of an artifact collected less than 400 days ago
  (`AshCompliance.Ownership.Retention.purge_floor_days/0`).

      defmodule MyApp.Compliance.ArchivedEvidence do
        use Ash.Resource,
          domain: MyApp.Compliance,
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer]

        use AshCompliance.Resources,
            {:evidence_archive, table: "evidence_artifact_archive", repo: MyApp.Repo}

        policies do
          # the host's read grant
        end
      end

  Then name it in configuration, so the freshness sweep and every other read of
  evidence for a period read the hot table and the archive together:

      config :ash_compliance, evidence_archive: MyApp.Compliance.ArchivedEvidence

  Options:

    * `:table` - **required**. The archive's table. The macro does not apply the
      package's `table_prefix`, so a host keeps a table it already has.
    * `:repo` - **required**. The host's repo. It must be the hot table's repo: a move
      copies and deletes in one transaction.
    * `:guard_function` - the guard trigger function's name. Default
      `"<table>_guard_fn"`.

  The trigger is `<table>_guard`, the statements `<table>_guard_function` and
  `<table>_guard_trigger`, the index `<table>_control_index` over organization,
  control and collection time. Actions: `:read` and `:for_control` (one
  organization's artifacts for one control, oldest first).
  """

  @hot_columns ~w(id organization_id control_id subject_type subject_id hash content
                  media_type collector method chain_of_custody retention_class
                  collected_at inserted_at)a

  @doc """
  The columns an archived artifact copies from the hot table, in order. They are every
  attribute of `AshCompliance.Resources.EvidenceArtifact`.
  """
  @spec columns() :: [atom()]
  def columns, do: @hot_columns

  @doc "True when `resource` was built with `{:evidence_archive, opts}`."
  @spec evidence_archive?(module()) :: boolean()
  def evidence_archive?(resource) when is_atom(resource) do
    Code.ensure_loaded?(resource) and function_exported?(resource, :spark_dsl_config, 0) and
      Spark.Dsl.Extension.get_persisted(resource, :ash_compliance_evidence_archive, false)
  end

  def evidence_archive?(_), do: false

  @doc false
  defmacro __using__(which)

  defmacro __using__({:evidence_archive, opts}) do
    opts = Enum.map(opts, fn {key, value} -> {key, Macro.expand(value, __CALLER__)} end)
    table = fetch!(opts, :table)
    repo = fetch!(opts, :repo)
    guard_function = Keyword.get(opts, :guard_function, "#{table}_guard_fn")

    case Enum.reject([table, guard_function], &identifier?/1) do
      [] -> :ok
      bad -> raise ArgumentError, "not plain SQL identifiers: #{inspect(bad)}"
    end

    floor = AshCompliance.Ownership.Retention.purge_floor_days()

    quote location: :keep do
      postgres do
        table(unquote(table))
        repo(unquote(repo))

        custom_indexes do
          index([:organization_id, :control_id, :collected_at],
            name: unquote("#{table}_control_index")
          )
        end

        custom_statements do
          statement unquote(:"#{table}_guard_function") do
            up(unquote(guard_function_sql(table, guard_function, floor)))
            down(unquote("DROP FUNCTION IF EXISTS #{guard_function}();"))
          end

          statement unquote(:"#{table}_guard_trigger") do
            up(unquote(guard_trigger_sql(table, guard_function)))
            down(unquote("DROP TRIGGER IF EXISTS #{table}_guard ON #{table};"))
          end
        end
      end

      actions do
        defaults([:read])
        default_accept([])

        read :for_control do
          description("One organization's archived artifacts for one control, oldest first.")

          argument(:organization_id, :uuid, allow_nil?: false)
          argument(:control_id, :string, allow_nil?: false)

          prepare(build(sort: [collected_at: :asc, id: :asc]))

          # Plain (unhygienic) variables: `expr` reads a variable as an attribute
          # reference only in the resource's own context.
          filter(
            expr(
              unquote(Macro.var(:organization_id, nil)) == ^arg(:organization_id) and
                unquote(Macro.var(:control_id, nil)) == ^arg(:control_id)
            )
          )
        end
      end

      attributes do
        # The hot row's id, copied rather than generated: a second copy of one artifact
        # conflicts instead of landing beside it.
        attribute :id, :uuid do
          primary_key?(true)
          allow_nil?(false)
          writable?(false)
          public?(true)
        end

        attribute(:organization_id, :uuid, allow_nil?: false, writable?: false, public?: true)
        attribute(:control_id, :string, allow_nil?: false, writable?: false, public?: true)
        attribute(:subject_type, :string, writable?: false, public?: true)
        attribute(:subject_id, :string, writable?: false, public?: true)
        attribute(:hash, :string, allow_nil?: false, writable?: false, public?: true)
        attribute(:content, :binary, writable?: false, public?: true)
        attribute(:media_type, :string, allow_nil?: false, writable?: false, public?: true)
        attribute(:collector, :string, allow_nil?: false, writable?: false, public?: true)
        attribute(:method, :string, allow_nil?: false, writable?: false, public?: true)
        attribute(:chain_of_custody, {:array, :map}, writable?: false, public?: true)
        attribute(:retention_class, :string, writable?: false, public?: true)

        attribute(:collected_at, :utc_datetime_usec,
          allow_nil?: false,
          writable?: false,
          public?: true
        )

        attribute(:inserted_at, :utc_datetime_usec,
          allow_nil?: false,
          writable?: false,
          public?: true
        )

        attribute :archived_at, :utc_datetime_usec do
          allow_nil?(false)
          writable?(false)
          public?(true)
          description("When the retention run copied this artifact out of the hot table.")
        end
      end

      @persist {:ash_compliance_evidence_archive, true}
    end
  end

  defmacro __using__(other) do
    raise ArgumentError,
          "use AshCompliance.Resources expects {:evidence_archive, opts}, got: " <>
            Macro.to_string(other)
  end

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> raise ArgumentError, "{:evidence_archive, opts} requires #{inspect(key)}"
    end
  end

  @doc false
  def identifier?(name) when is_binary(name),
    do: Regex.match?(~r/\A[a-z_][a-z0-9_]{0,62}\z/, name)

  def identifier?(_), do: false

  defp guard_function_sql(table, function, floor) do
    """
    CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger AS $fn$
    BEGIN
      IF TG_OP = 'DELETE' AND OLD.collected_at < now() - interval '#{floor} days' THEN
        RETURN OLD;
      END IF;

      RAISE EXCEPTION '#{table} keeps every artifact for #{floor} days; % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation',
              HINT = 'Archived evidence is never edited, and is purged only after #{floor} days.';
    END;
    $fn$ LANGUAGE plpgsql;
    """
  end

  defp guard_trigger_sql(table, function) do
    """
    CREATE OR REPLACE TRIGGER #{table}_guard
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{function}();
    """
  end
end
