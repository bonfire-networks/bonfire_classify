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

  Structure only: the circles. Which content boundary the group's posts default to is POLICY, and belongs to the caller, because both callers know it better than a scaffold can. `Classify.Boundaries.init_boundaries/4` takes it from `resolve_dims/1`, which derives it from the visibility the group actually has when the creator named no default; `Scaffold.Groups.DataMigration` takes it from the group's existing value. A default written here would run before either and overwrite both.

  ## Examples

      > Bonfire.Boundaries.Scaffold.Groups.create_default_boundaries(group)
  """
  def create_default_boundaries(group, creator \\ nil) do
    with {:ok, members_circle} <- Circles.get_or_create_stereotype_circle(group, :group_members),
         {:ok, mods_circle} <-
           Circles.get_or_create_stereotype_circle(group, :group_moderators) do
      if creator do
        Circles.add_to_circles(creator, members_circle)
        Circles.add_to_circles(creator, mods_circle)
      end

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

  @doc """
  Lists the member subjects of a group's moderators circle.

  Read-only — unlike `moderators_circle/1` it never creates the circle (so it's
  safe to call on any category). Returns `[]` when there's no moderators circle.
  """
  def list_moderators(group) do
    case Circles.get_stereotype_circles(group, [:group_moderators]) do
      [circle | _] ->
        Circles.list_members(circle, paginate: false)
        |> Enum.map(&e(&1, :subject, nil))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end
end
