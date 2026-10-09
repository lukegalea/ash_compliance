# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.TenantPolicySet.SetActiveBundle do
  @moduledoc """
  `set_active_bundle` change: refuses to point a tenant at anything but an
  active bundle. The bundle id comes from the argument; the bundle's status
  is read inside the action, never trusted from the caller.

  The check reads the bundle's **current** status (a plain as-of-now get),
  deliberately: the pointer is a current-pointer, and the refusal guards
  what is active at write time — pointing a tenant at a bundle that is only
  active at some past or future instant is exactly the mistake this refuses.
  The refusal messages are byte-identical before and after the temporal
  swap.

  Temporal-safe: reads an argument, does one present-tense cross-resource
  read (by design, see above), and never touches `as_of` or the wall clock
  on the write itself.
  """

  use Ash.Resource.Change

  @impl true
  def temporal_safe?(_opts), do: true

  alias AshCompliance.Domain
  alias AshCompliance.Resources.PolicyBundle

  @impl true
  def change(changeset, _opts, _context) do
    # `active_policy_bundle_id` is an accepted attribute, so a caller's input
    # lands in the changeset's attributes, not its arguments — read both
    # (the `CompileChange` dual-read precedent). This is a latent-defect fix
    # surfaced by this slice: the suite never exercised this host-facing
    # action before, and a bare `get_argument` read always saw nil.
    bundle_id =
      Ash.Changeset.get_argument(changeset, :active_policy_bundle_id) ||
        Ash.Changeset.get_attribute(changeset, :active_policy_bundle_id)

    # Trusted machinery: this read runs inside the action itself, with no
    # user request attached, so `authorize?: false` is deliberate.
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Domain.get_policy_bundle_by_id(bundle_id, authorize?: false) do
        {:ok, %PolicyBundle{status: :active}} ->
          changeset

        {:ok, %PolicyBundle{status: status}} ->
          Ash.Changeset.add_error(
            changeset,
            "cannot activate tenant policy set against a bundle with status #{inspect(status)}"
          )

        {:ok, nil} ->
          Ash.Changeset.add_error(changeset, "policy bundle #{inspect(bundle_id)} does not exist")

        {:error, _} ->
          Ash.Changeset.add_error(changeset, "policy bundle #{inspect(bundle_id)} does not exist")
      end
    end)
  end
end
