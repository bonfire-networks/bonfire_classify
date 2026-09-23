if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.ModeratorsAreMembersTest do
    @moduledoc """
    A group's moderators read what is posted in it, members-private groups included.

    A post in a members-private group is readable by the group and its members circle. Moderators sit in a circle of their own, so a moderator who was never a member could moderate the group yet not read a post in it, their own replies included: a reply copies its thread's audience and adds only the people it mentions, never its author. Two things close that, each tested here: making someone a moderator also makes them a member (and the backfill does the same for moderators made before), and a members-private group's posts are addressed to its moderators circle as well, so a moderator outside the members circle still reads them.

    Membership only: none of this makes a moderator FOLLOW the group, so its feed does not start arriving in theirs.
    """
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Classify.Categories
    alias Bonfire.Classify.Boundaries, as: ClassifyBoundaries
    alias Bonfire.Boundaries.Scaffold.Groups, as: ScaffoldGroups
    alias Bonfire.Boundaries.Circles
    alias Bonfire.Social.Graph.Follows
    alias Bonfire.Me.Fake

    setup do
      Process.put(:federating, false)
      :ok
    end

    defp members_private_group(creator) do
      Bonfire.Classify.Simulate.fake_group!(creator, %{
        membership: "invite_only",
        visibility: "members:private",
        participation: "group_members",
        default_content_visibility: "members:private"
      })
    end

    # a moderator who is not a member, as `add_moderator/4` used to leave them: in the moderators circle and nothing else
    defp moderator_outside_members(group) do
      moderator = Fake.fake_user!()
      {:ok, mods} = ScaffoldGroups.moderators_circle(group)
      Circles.add_to_circles(moderator, mods)
      moderator
    end

    # a reply as the thread page makes one: it copies the thread's audience (`clone_context`, keyed on the thread root) and addresses the person being answered
    defp reply_in_thread(user, root, html) do
      {:ok, reply} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: html}, reply_to_id: id(root)},
          boundary: ["clone_context"],
          context_id: id(root),
          to_circles: [e(root, :created, :creator_id, nil)] |> Enum.reject(&is_nil/1)
        )

      reply
    end

    test "making someone a moderator makes them a member, without making them follow" do
      creator = Fake.fake_user!()
      moderator = Fake.fake_user!()
      group = members_private_group(creator)

      refute Categories.member?(moderator, group), "control: not a member before"

      assert {:ok, _} = Categories.add_moderator(creator, group, id(moderator))

      assert Categories.member?(moderator, group)

      refute Follows.following?(moderator, group),
             "membership only: becoming a moderator must not start the group's feed arriving in theirs"
    end

    test "a moderator who is not a member reads posts in a members-private group, and their own reply" do
      creator = Fake.fake_user!()
      group = members_private_group(creator)
      moderator = moderator_outside_members(group)

      refute Categories.member?(moderator, group),
             "control: the case this is about, a moderator outside the members circle"

      post =
        Bonfire.Classify.Simulate.fake_post_in_group!(creator, group, "<p>members only talk</p>")

      assert Bonfire.Boundaries.can?(moderator, :read, post),
             "a moderator cannot moderate what they cannot read"

      post = repo().preload(post, :created)
      reply = reply_in_thread(moderator, post, "<p>my reply as a moderator</p>")

      assert Bonfire.Boundaries.can?(moderator, :read, reply),
             "the reported case: a moderator lost sight of their own reply in the thread"
    end

    describe "the backfill" do
      defp run_backfill do
        Bonfire.Classify.Boundaries.ModeratorsAreMembersDataMigration.base_query()
        |> repo().all()
        |> Bonfire.Classify.Boundaries.ModeratorsAreMembersDataMigration.migrate()
      end

      test "makes an existing moderator a member, without making them follow" do
        creator = Fake.fake_user!()
        group = members_private_group(creator)
        moderator = moderator_outside_members(group)

        refute Categories.member?(moderator, group), "control: outside the members circle before"

        run_backfill()

        assert Categories.member?(moderator, group)
        refute Follows.following?(moderator, group)
      end

      test "changes nothing when run again" do
        creator = Fake.fake_user!()
        group = members_private_group(creator)
        moderator = moderator_outside_members(group)

        run_backfill()
        run_backfill()

        assert Categories.member?(moderator, group)
        refute Follows.following?(moderator, group)
      end
    end
  end
end
