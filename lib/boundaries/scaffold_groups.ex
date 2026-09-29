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

      moderators_acl(group)
      administer_acl(group)

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
  Returns the ACL through which a group's moderators moderate what is published in it, creating it if it doesn't exist.

  One per group, like each user's `i_may_administer`: the group is its caretaker, and it grants the group's moderators circle the `:moderate` role. Attaching this one ACL to each object costs a single `Controlled` row, where granting on each object would create a custom ACL and grants per object, and promoting or demoting a moderator changes the circle rather than anything per object.
  """
  def moderators_acl(group) do
    with {:ok, circle} <- moderators_circle(group) do
      # the group too, so what it sends in its own name (a remote community's moderation included) passes the same verb checks as its moderators
      get_or_create_stereotype_acl(group, :group_mods_may_moderate, [
        {circle, :moderate},
        {group, :moderate}
      ])
    end
  end

  @doc """
  Returns the group's own `i_may_administer` ACL, creating it and attaching it to the group if it doesn't exist.

  The same stereotype every user has over their own account, granting the group `:administer` over itself, so what it does in its own name passes the same verb checks as anyone else's rather than being accepted for coming from its host.
  """
  def administer_acl(group) do
    get_or_create_stereotype_acl(group, :i_may_administer, [{group, :administer}], fn acl ->
      Bonfire.Boundaries.Controlleds.add_acls(group, acl)
    end)
  end

  @doc """
  Returns the ACL through which a members-only group's members and moderators participate in what is published in it, creating it if it doesn't exist.

  Grants both circles the `:participate` role, which is what each post's own ACL granted them when a group's composer addressed them per post. One shared ACL costs each post a single `Controlled` row instead.
  """
  def members_acl(group) do
    with {:ok, members} <- members_circle(group),
         {:ok, moderators} <- moderators_circle(group) do
      get_or_create_stereotype_acl(group, :group_members_may_participate, [
        {members, :participate},
        {moderators, :participate}
      ])
    end
  end

  # one per group and stereotype, with the group as caretaker, found again by its stereotype. `on_create` runs only when it is first made, e.g. to attach it somewhere once, since an object can hold an ACL only once
  defp get_or_create_stereotype_acl(group, stereotype, circle_roles, on_create \\ fn _ -> nil end) do
    stereotype_id = Bonfire.Boundaries.Acls.get_id!(stereotype)

    case Bonfire.Boundaries.find_caretaker_stereotype(
           group,
           [stereotype_id],
           Bonfire.Data.AccessControl.Acl
         ) do
      %{} = acl ->
        {:ok, acl}

      nil ->
        with {:ok, acl} <-
               Bonfire.Boundaries.Acls.create(%{stereotyped: %{stereotype_id: stereotype_id}},
                 current_user: group
               ) do
          for {circle, role} <- circle_roles,
              do: Bonfire.Boundaries.Grants.grant_role(id(circle), acl, role, current_user: group)

          on_create.(acl)
          {:ok, acl}
        end
    end
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
