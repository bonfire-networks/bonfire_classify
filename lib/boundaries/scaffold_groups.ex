defmodule Bonfire.Boundaries.Scaffold.Groups do
  @moduledoc """
  Creates default boundary setup for a new group (Category with type: :group).

  Groups get a dedicated `members` circle (stereotyped) that is used for membership
  tracking and member counts. Topics do not need this — they use follows only.
  """

  use Bonfire.Common.Utils
  import Bonfire.Boundaries.Integration

  alias Bonfire.Boundaries.Circles

  @doc """
  Creates the default boundaries for a newly-created group, including a stereotyped
  members circle owned by the group itself as caretaker.

  ## Examples

      > Bonfire.Boundaries.Scaffold.Groups.create_default_boundaries(group)
  """
  def create_default_boundaries(group, creator \\ nil, opts \\ []) do
    with {:ok, members_circle} <- Circles.get_or_create_stereotype_circle(group, :group_members),
         {:ok, _mods_circle} <-
           Circles.get_or_create_stereotype_circle(group, :group_moderators) do
      if creator do
        Circles.add_to_circles(creator, members_circle)
        Circles.add_to_circles(creator, _mods_circle)
      end

      default_visibility = Keyword.get(opts, :visibility, "global")

      Bonfire.Common.Settings.put(
        [:default_content_visibility],
        Bonfire.Classify.Boundaries.default_content_visibility_for(default_visibility),
        scope: group
      )

      {:ok, members_circle}
    end
  end

  @doc """
  Returns the members circle for a group, creating it if it doesn't exist.
  """
  def members_circle(group) do
    Circles.get_or_create_stereotype_circle(group, :group_members)
  end

  @doc """
  Returns the moderators circle for a group, creating it if it doesn't exist.
  """
  def moderators_circle(group) do
    Circles.get_or_create_stereotype_circle(group, :group_moderators)
  end
end
