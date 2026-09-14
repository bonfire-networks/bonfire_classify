if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupMemberFollowTest do
    @moduledoc """
    Members can follow their own group, however closed it is.

    Following a group is normally granted by its VISIBILITY: the `*_see_interact` / `*_read_interact` ACLs list `:follow` outright, and `nonfederated` / `local` name `locals_may_follow`. A `members:private` group has an empty visibility signature by design, so none of that reaches it and membership itself has to convey following.

    That used to happen by accident: the members circle is granted `:interact` or `:contribute`, and `:follow` rode inside every role from `interact` up. It no longer does — it is granted where it is meant, like `:join` — so the members circle is granted it explicitly. The pair below separates "members may follow" from "anyone may follow", which a closed group must still refuse.
    """
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils

    alias Bonfire.Boundaries.Circles
    alias Bonfire.Boundaries.Queries
    alias Bonfire.Classify.Simulate
    alias Bonfire.Me.Fake

    setup do
      # nothing here federates; applying boundaries otherwise spawns federation tasks with no DB ownership in tests
      Process.put(:federating, false)
      :ok
    end

    defp closed_group(creator) do
      Simulate.fake_group!(creator, %{
        membership: "invite_only",
        visibility: "members:private",
        participation: "group_members",
        default_content_visibility: "members:private"
      })
    end

    test "a member may follow a closed group" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()

      group = closed_group(creator)

      {:ok, circle} = Bonfire.Boundaries.Scaffold.Groups.members_circle(group)
      Circles.add_to_circles(member, circle)

      assert :follow in Queries.permitted_verbs_on(member, group, [:follow]),
             "a closed group grants nothing through visibility, so membership is the only thing that can convey following, and members who unfollow must be able to follow again"
    end

    test "a stranger may not follow a closed group" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()

      group = closed_group(creator)

      refute :follow in Queries.permitted_verbs_on(stranger, group, [:follow]),
             "the control: the grant above has to come from membership rather than from the group being followable by anyone"
    end
  end
end
