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
      Circles.add_to_circles(member, circle, skip_boundary_check: true)

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

    # `leave_group/3` keeps the follow so someone can keep reading a group they left, which only holds where the group still lets a non-member follow
    test "leaving a closed group does not keep their follow, nor its later posts" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()
      group = closed_group(creator)

      {:ok, circle} = Bonfire.Boundaries.Scaffold.Groups.members_circle(group)
      Circles.add_to_circles(member, circle, skip_boundary_check: true)

      assert {:ok, _} = Bonfire.Classify.Categories.follow_group(member, group)
      assert Bonfire.Social.Graph.Follows.following?(member, group), "control: following"

      publish = fn text ->
        {:ok, post} =
          Bonfire.Posts.publish(
            current_user: creator,
            post_attrs: %{post_content: %{html_body: "<p>#{text}</p>"}},
            boundary: "mentions",
            publish_in: uid(group)
          )

        post
      end

      assert Bonfire.Social.FeedLoader.feed_contains?(:my, publish.("while a member"),
               current_user: member
             ),
             "control: a member's feed gets the group's posts"

      assert {:ok, _} = Bonfire.Classify.Categories.leave_group(member, group)

      refute :follow in Queries.permitted_verbs_on(member, group, [:follow]),
             "control: no longer a member, so nothing grants them the follow"

      refute Bonfire.Social.FeedLoader.feed_contains?(:my, publish.("after they left"),
               current_user: member
             )

      refute Bonfire.Social.Graph.Follows.following?(member, group)
    end
  end
end
