defmodule Bonfire.Classify.Boundaries.GroupModeratorsGrantDataMigration do
  @moduledoc """
  Gives the moderators circle of every group its `:moderate` role on the group, so the people listed as a group's moderators can act as moderators of it, settings included.

  `Bonfire.Boundaries.Scaffold.Groups.empower_moderators_circle/2` writes that role, and `Bonfire.Boundaries.Scaffold.Groups.DataMigration` ran it for older groups without checking it had worked: a group whose moderators circle was duplicated, or whose role row was lost, kept a list of moderators who held nothing on it.

  A group with two moderators circles has them merged first (`Bonfire.Boundaries.Scaffold.DuplicateStereotypeCirclesDataMigration`, which the migration runs just before this one), as `empower_moderators_circle/2` refuses a group with two. A group that still fails is logged and left as it was, so one group can't stop the others.

  Safe to re-run: granting a role the circle already holds changes nothing.
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
    Enum.each(results, &safely_empower/1)
  end

  # one at a time, so a group that fails loses only itself, not the rest of its batch
  defp safely_empower(group) do
    case Bonfire.Boundaries.Scaffold.Groups.empower_moderators_circle(group) do
      {:error, _} = failed ->
        error(
          failed,
          "Could not give the moderators of the group #{inspect(group)} their role, going on"
        )

      _ ->
        :ok
    end
  rescue
    e ->
      error(
        e,
        "Could not give the moderators of the group #{inspect(group)} their role, going on"
      )
  catch
    kind, reason ->
      error(
        {kind, reason},
        "Could not give the moderators of the group #{inspect(group)} their role, going on"
      )
  end
end
