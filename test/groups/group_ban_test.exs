if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupBanTest do
    @moduledoc """
    A group's moderator banning someone from it. A ban is a silence or a ghost with the GROUP as the blocker: `Blocks.block(person, type, current_user: moderator, on_behalf_of: group)`, the same call as a personal block plus who it is on behalf of. So the ban lives in the group's own block circles, and the group's block ACLs (created with the group) deny the person on the group and on what is published in it.

    The moderator chooses what it stops:
    - SILENCE is a participation ban, Lemmy's meaning: no posting into the group, replying, liking or boosting there. They can still read it, and keep following it
    - GHOST stops everything, seeing the group and its posts included

    Only someone who may moderate the group (`:mediate`) may block on its behalf. Federation is documented in `group_outgoing_test.exs` and `threadiverse_moderation_test.exs`.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Me.Fake
    alias Bonfire.Boundaries
    alias Bonfire.Boundaries.Blocks
    alias Bonfire.Classify.Categories
    alias Bonfire.Classify.Simulate
    alias Bonfire.Social.Graph.Follows

    setup do
      Process.put(:federating, false)

      moderator = Fake.fake_user!()
      person = Fake.fake_user!()
      member = Fake.fake_user!()

      group =
        Simulate.fake_group!(moderator, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      assert {:ok, _} = Categories.join_and_follow_group(member, group)
      assert {:ok, _} = Follows.follow(person, group)
      post = Simulate.fake_post_in_group!(member, group, "<p>posted before any ban</p>")

      # the wiring a ban works through, found rather than created here, so this says which half is missing: the group has its block ACLs from creation, and the post published in it carries them
      block_acl_ids =
        for stereotype <- [:ghosted_cannot_anything, :silenced_cannot_reach_me],
            %{} = acl <- [
              Bonfire.Boundaries.Scaffold.Groups.find_stereotype_acl(group, stereotype)
            ],
            do: id(acl)

      assert length(block_acl_ids) == 2, "control: the group has its block ACLs from creation"

      on_post = Enum.map(Bonfire.Boundaries.Controlleds.list_on_object(post), & &1.acl_id)

      assert Enum.all?(block_acl_ids, &(&1 in on_post)),
             "control: the post published in the group carries them"

      # the controls: before the ban, the person may do everything the ban takes away, so a refusal below is the ban rather than the fixture
      for verb <- [:see, :read, :tag, :follow] do
        assert Boundaries.can?(person, verb, group),
               "control: may #{verb} the group before the ban"
      end

      for verb <- [:see, :read, :reply, :like, :boost] do
        assert Boundaries.can?(person, verb, post), "control: may #{verb} the post before the ban"
      end

      assert Follows.following?(person, group), "control: they follow the group"

      {:ok, moderator: moderator, person: person, member: member, group: group, post: post}
    end

    test "a silenced person can't post into the group or interact with its posts, but can still read and follow it",
         %{moderator: moderator, person: person, group: group, post: post} do
      assert {:ok, _} =
               Blocks.block(person, :silence, current_user: moderator, on_behalf_of: group)

      refute Boundaries.can?(person, :tag, group), "can't post into the group"

      for verb <- [:reply, :like, :boost] do
        refute Boundaries.can?(person, verb, post),
               "can't #{verb} a post that was in the group before the ban"
      end

      for verb <- [:see, :read, :follow] do
        assert Boundaries.can?(person, verb, group), "can still #{verb} the group"
      end

      assert Boundaries.can?(person, :read, post), "can still read its posts"
    end

    # their own posts in the group included: silenced, the author can't keep a thread going there either, as on the threadiverse. Checked through what publishing a reply checks (`Threads.find_reply_to/2`, which `boundarise`s on `:reply` and raises when refused): `Boundaries.can?/4` says yes to an object's creator before looking at any grant, so it would answer "may reply" here although the reply is refused (left as it is, Mayel, 12 October)
    test "a silenced author can't reply to their own post in the group", %{
      moderator: moderator,
      member: author,
      group: group,
      post: post
    } do
      assert {:ok, _} = Bonfire.Social.Threads.find_reply_to(%{reply_to_id: id(post)}, author),
             "control: the author may reply before"

      assert {:ok, _} =
               Blocks.block(author, :silence, current_user: moderator, on_behalf_of: group)

      assert_raise Bonfire.Fail, fn ->
        Bonfire.Social.Threads.find_reply_to(%{reply_to_id: id(post)}, author)
      end
    end

    test "a ghosted person can't see the group or its posts", %{
      moderator: moderator,
      person: person,
      group: group,
      post: post
    } do
      assert {:ok, _} =
               Blocks.block(person, :ghost, current_user: moderator, on_behalf_of: group)

      for verb <- [:see, :read, :tag, :follow] do
        refute Boundaries.can?(person, verb, group), "can't #{verb} the group"
      end

      for verb <- [:see, :read, :reply] do
        refute Boundaries.can?(person, verb, post), "can't #{verb} a post in the group"
      end
    end

    # the group is the blocker, so the ban is in the group's lists and not the moderator's: the moderator hasn't personally blocked anyone, and stepping down as moderator doesn't lift it
    test "the ban is the group's, not the moderator's", %{
      moderator: moderator,
      person: person,
      group: group
    } do
      assert {:ok, _} =
               Blocks.block(person, :silence, current_user: moderator, on_behalf_of: group)

      assert Blocks.is_blocked?(person, :silence, current_user: group)
      refute Blocks.is_blocked?(person, :silence, current_user: moderator)
    end

    for type <- [:silence, :ghost] do
      test "unbanning a #{type} restores what it took away", %{
        moderator: moderator,
        person: person,
        group: group,
        post: post
      } do
        type = unquote(type)

        assert {:ok, _} =
                 Blocks.block(person, type, current_user: moderator, on_behalf_of: group)

        refute Boundaries.can?(person, :reply, post), "control: the ban took effect"

        assert {:ok, _} =
                 Blocks.unblock(person, type, current_user: moderator, on_behalf_of: group)

        assert Boundaries.can?(person, :tag, group)
        assert Boundaries.can?(person, :reply, post)
      end
    end

    # `also_unfollow_and_notify`, as for a personal block, is what severs follows and federates. For a ban, a ghost ends their follow of the group (it no longer reaches them), while a silence keeps it, since a silenced person may still read
    test "with also_unfollow_and_notify, a ghost ends their follow of the group", %{
      moderator: moderator,
      person: person,
      group: group
    } do
      assert {:ok, _} =
               Blocks.block(person, :ghost,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      refute Follows.following?(person, group)
    end

    test "with also_unfollow_and_notify, a silence keeps their follow of the group", %{
      moderator: moderator,
      person: person,
      group: group
    } do
      assert {:ok, _} =
               Blocks.block(person, :silence,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      assert Follows.following?(person, group)

      # the control, so the kept follow means the silence and not the box doing nothing: ghosting another follower the same way does end theirs
      other = Fake.fake_user!()
      assert {:ok, _} = Follows.follow(other, group)

      assert {:ok, _} =
               Blocks.block(other, :ghost,
                 current_user: moderator,
                 on_behalf_of: group,
                 also_unfollow_and_notify: true
               )

      refute Follows.following?(other, group), "control: the ghost's follow ends"
    end

    test "a member who isn't a moderator can't ban on the group's behalf", %{
      member: member,
      person: person,
      group: group,
      post: post
    } do
      assert {:error, _} = Blocks.block(person, :ghost, current_user: member, on_behalf_of: group)

      assert Boundaries.can?(person, :see, group), "the refused ban changed nothing"
      assert Boundaries.can?(person, :reply, post)
      refute Blocks.is_blocked?(person, :ghost, current_user: group)
    end

    test "nor can they lift one", %{
      moderator: moderator,
      member: member,
      person: person,
      group: group,
      post: post
    } do
      assert {:ok, _} =
               Blocks.block(person, :silence, current_user: moderator, on_behalf_of: group)

      assert {:error, _} =
               Blocks.unblock(person, :silence, current_user: member, on_behalf_of: group)

      refute Boundaries.can?(person, :reply, post), "the ban stands"
    end
  end
end
