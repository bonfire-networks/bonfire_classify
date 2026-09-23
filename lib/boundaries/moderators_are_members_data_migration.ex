defmodule Bonfire.Classify.Boundaries.ModeratorsAreMembersDataMigration do
  @moduledoc """
  Makes every existing moderator of a group a member of it.

  A members-private group's posts are addressed to its members circle, and moderators sit in a circle of their own, so a moderator who was never a member could moderate the group yet not read a post in it, their own replies included. `Categories.add_moderator/4` now makes someone a member as well; this does the same for those made moderator before it did.

  Membership only: nobody is made to follow the group, nor is it pinned to their sidebar.

  Safe to re-run: a moderator who is already a member is skipped.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Scaffold.Groups, as: ScaffoldGroups
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
    Enum.each(results, fn group ->
      # read-only, so a group without a moderators circle is skipped rather than given one
      case ScaffoldGroups.list_moderators(group) do
        [] ->
          :skip

        moderators ->
          with {:ok, members} <- ScaffoldGroups.members_circle(group) do
            moderators
            |> Enum.reject(&Circles.is_encircled_by?(&1, members))
            |> Enum.each(fn moderator ->
              info(id(moderator), "group #{id(group)}: making a moderator a member")
              Circles.add_to_circles(moderator, members)
            end)
          end
      end
    end)
  end
end
