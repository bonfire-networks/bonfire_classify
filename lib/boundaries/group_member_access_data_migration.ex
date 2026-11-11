defmodule Bonfire.Classify.Boundaries.GroupMemberAccessDataMigration do
  @moduledoc """
  Gives the members of every group the per-group role that lets them read it.

  Members read a group through the members circle's role on the group itself, which only `Bonfire.Classify.Boundaries.init_boundaries/4` and `replace/4` wrote. `Bonfire.Boundaries.Scaffold.Groups.DataMigration` scaffolded older groups without it, so their members read through the global participation ACLs, which stopped granting read when the group dimensions stopped granting see. A group whose visibility is a preview then shows its own members the gate.

  The visibility and participation are read back from each group's own ACLs, as `replace/4` is given them. Safe to re-run: `regrant_role/4` clears only the participation roles, so anything else an admin granted the circle survives.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  @impl DataMigration
  def base_query do
    from(c in Bonfire.Classify.Category,
      where: c.type == :group,
      select: %{id: c.id}
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      async: true,
      batch_size: 500,
      throttle_ms: 1_000,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(results) do
    Enum.each(results, &safely_grant/1)
  end

  @doc "Grants the group's members circle its role on the group, from the visibility and participation the group's ACLs carry. The group acts for itself, as it does when it empowers its moderators."
  def grant_member_access(group) do
    dims = Bonfire.Boundaries.Presets.group_dimension_slugs(group)

    Bonfire.Classify.Boundaries.grant_member_access(
      group,
      dims[:visibility],
      dims[:participation],
      group
    )
  end

  # one at a time, so a group that fails loses only itself, not the rest of its batch
  defp safely_grant(group) do
    grant_member_access(group)
  rescue
    e ->
      error(e, "Could not grant members access to the group #{inspect(group)}, going on")
  catch
    kind, reason ->
      error(
        {kind, reason},
        "Could not grant members access to the group #{inspect(group)}, going on"
      )
  end
end
