defmodule AshCompliance.ActivateSuccessionTest do
  @moduledoc """
  `:activate` succeeds the in-force predecessor: activating revision 2
  while revision 1 is active retires the predecessor in the same
  transaction, at the same write instant — the documented
  activate-2-then-retire-1 lifecycle needs no manual retire between
  revisions. Refusal messages of the lifecycle guards are unchanged.
  """

  use AshCompliance.DataCase, async: false

  require Ash.Query

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp hours_after(at, hours), do: DateTime.add(at, hours * 3600, :second)

  defp draft(org, name, opts \\ []) do
    AshCompliance.Test.Support.rule_set_revision(
      organization_id: org,
      name: name,
      revision: Keyword.get(opts, :revision, "1"),
      as_of: now()
    )
  end

  defp lifecycle(revision, at, actions) do
    Enum.reduce(actions, revision, fn action, rev ->
      apply(AshCompliance.Domain, :"#{action}_rule_set_revision!", [
        rev,
        [authorize?: false, as_of: at]
      ])
    end)
  end

  defp activate(revision, at, opts \\ []) do
    case Keyword.get(opts, :effective_at) do
      nil ->
        AshCompliance.Domain.activate_rule_set_revision!(revision,
          authorize?: false,
          as_of: at
        )

      instant ->
        AshCompliance.Domain.activate_rule_set_revision!(revision, %{effective_at: instant},
          authorize?: false,
          as_of: at
        )
    end
  end

  defp actives_at(org, at) do
    AshCompliance.Resources.RuleSetRevision
    |> Ash.Query.filter(organization_id == ^org and status == :active)
    |> Ash.read!(authorize?: false, as_of: at)
  end

  test "activating revision 2 retires the active revision 1 at the same instant" do
    org = Ecto.UUID.generate()
    name = "succession-" <> Integer.to_string(System.unique_integer([:positive]))

    now = now()

    first =
      draft(org, name, revision: "1")
      |> lifecycle(now, [:validate, :approve])
      |> activate(now)

    t2 = hours_after(now, 1)

    second =
      draft(org, name, revision: "2")
      |> lifecycle(now(), [:validate, :approve])
      |> activate(t2)

    # Exactly one active, and it is the successor.
    assert [%{id: id}] = actives_at(org, t2)
    assert id == second.id

    # The predecessor's period closed at the successor's activation
    # instant: one second before t2, revision 1 is still in force.
    before = DateTime.add(t2, -1, :second)
    assert [%{id: id1}] = actives_at(org, before)
    assert id1 == first.id
  end

  test "activating at the house clock succeeds the predecessor too" do
    org = Ecto.UUID.generate()
    name = "clock-" <> Integer.to_string(System.unique_integer([:positive]))

    _first =
      draft(org, name, revision: "1")
      |> lifecycle(now(), [:validate, :approve])
      |> activate(now())

    second =
      draft(org, name, revision: "2")
      |> lifecycle(now(), [:validate, :approve])

    AshCompliance.Domain.activate_rule_set_revision!(second, authorize?: false)

    actives =
      AshCompliance.Resources.RuleSetRevision
      |> Ash.Query.filter(organization_id == ^org and name == ^name and status == :active)
      |> Ash.read!(authorize?: false)

    assert [%{id: id}] = actives
    assert id == second.id
  end
end
