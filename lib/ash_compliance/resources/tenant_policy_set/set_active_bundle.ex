# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Resources.TenantPolicySet.SetActiveBundle do
  @moduledoc false

  # `set_active_bundle` change: refuses to point a tenant at anything but an
  # active bundle. The bundle id comes from the argument; the bundle's status
  # is read inside the action, never trusted from the caller.

  use Ash.Resource.Change

  alias AshCompliance.Domain
  alias AshCompliance.Resources.PolicyBundle

  @impl true
  def change(changeset, _opts, _context) do
    bundle_id = Ash.Changeset.get_argument(changeset, :active_policy_bundle_id)

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
