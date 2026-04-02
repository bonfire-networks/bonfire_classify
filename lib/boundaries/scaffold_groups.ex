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
  def create_default_boundaries(group, creator \\ nil) do
    with {:ok, circle} <- Circles.get_or_create_stereotype_circle(group, :group_members) do
      if creator, do: Circles.add_to_circles(creator, circle)
      {:ok, circle}
    end
  end

  @doc """
  Returns the members circle for a group, creating it if it doesn't exist.
  """
  def members_circle(group) do
    Circles.get_or_create_stereotype_circle(group, :group_members)
  end
end
