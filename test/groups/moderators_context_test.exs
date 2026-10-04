if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.ModeratorsContextTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Me.Fake
    alias Bonfire.Classify.Categories
    alias Bonfire.Boundaries

    setup do
      Process.put(:federating, false)
      :ok
    end

    test "add_moderator promotes a user (empowers :mediate, lists them)" do
      creator = Fake.fake_user!()
      user = Fake.fake_user!()
      group = fake_group!(creator)

      assert {:ok, %{role: "moderator"}} = Categories.add_moderator(creator, group, id(user))

      assert Boundaries.can?(user, :mediate, group)
      assert Categories.member_role(user, group) == "moderator"
      assert Enum.any?(Categories.moderators(group), &(id(&1) == id(user)))
    end

    # promoting also adds them to the members circle, which a member is already in: that second membership is refused by the circle's unique index, and promoting must still succeed rather than fail on it
    test "add_moderator promotes someone who already joined, who stays a member once" do
      creator = Fake.fake_user!()
      user = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, _} = Categories.join_and_follow_group(user, group, skip_boundary_check: true)
      # the positive first: they did join
      assert Categories.member?(user, group)

      assert {:ok, %{role: "moderator"}} = Categories.add_moderator(creator, group, id(user))

      assert Boundaries.can?(user, :mediate, group)
      assert Categories.member?(user, group)

      {:ok, members} = Categories.members_circle(group)

      assert Bonfire.Common.Repo.aggregate(
               Ecto.Query.where(
                 Bonfire.Data.AccessControl.Encircle,
                 subject_id: ^id(user),
                 circle_id: ^id(members)
               ),
               :count
             ) == 1
    end

    test "remove_moderator demotes a user" do
      creator = Fake.fake_user!()
      user = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, _} = Categories.add_moderator(creator, group, id(user))
      assert Boundaries.can?(user, :mediate, group)

      assert {:ok, true} = Categories.remove_moderator(creator, group, id(user))

      refute Boundaries.can?(user, :mediate, group)
      refute Enum.any?(Categories.moderators(group), &(id(&1) == id(user)))
    end

    test "a non-moderator cannot add a moderator" do
      creator = Fake.fake_user!()
      rando = Fake.fake_user!()
      target = Fake.fake_user!()
      group = fake_group!(creator)

      assert {:error, _} = Categories.add_moderator(rando, group, id(target))
      refute Boundaries.can?(target, :mediate, group)
    end

    test "a promoted moderator can in turn promote others (:mediate gate)" do
      creator = Fake.fake_user!()
      mod = Fake.fake_user!()
      target = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, _} = Categories.add_moderator(creator, group, id(mod))
      assert {:ok, %{role: "moderator"}} = Categories.add_moderator(mod, group, id(target))
      assert Boundaries.can?(target, :mediate, group)
    end

    test "a moderator is allowed to manage the group (the gate used for creating topics)" do
      creator = Fake.fake_user!()
      mod = Fake.fake_user!()
      plain = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, _} = Categories.add_moderator(creator, group, id(mod))

      # `ensure_update_allowed/2` is the predicate gating topic creation + settings
      assert Bonfire.Classify.ensure_update_allowed(mod, group)
      refute Bonfire.Classify.ensure_update_allowed(plain, group)
    end

    test "a moderator can :edit the group (gates avatar/banner uploads & profile edits)" do
      creator = Fake.fake_user!()
      mod = Fake.fake_user!()
      plain = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, _} = Categories.add_moderator(creator, group, id(mod))

      # the upload path (Bonfire.Files.LiveHandler) authorizes with `can?(user, :edit, object)`,
      # so the :moderate role must include the :edit verb
      assert Boundaries.can?(mod, :edit, group)
      refute Boundaries.can?(plain, :edit, group)
    end

    test "the :moderate role is granted to the circle, so circle members inherit it automatically" do
      creator = Fake.fake_user!()
      first = Fake.fake_user!()
      later = Fake.fake_user!()
      group = fake_group!(creator)

      # promoting the first moderator empowers the moderators circle on the group
      {:ok, _} = Categories.add_moderator(creator, group, id(first))

      # a user added DIRECTLY to the circle (not via add_moderator) is now a moderator
      {:ok, circle} = Categories.moderators_circle(group)
      Bonfire.Boundaries.Circles.add_to_circles(later, circle)

      assert Boundaries.can?(later, :mediate, group),
             "expected a circle member to inherit :mediate from the circle grant"

      assert Enum.any?(Categories.moderators(group), &(id(&1) == id(later)))
    end

    describe "remove_post_from_group/3" do
      setup do
        creator = Fake.fake_user!()
        moderator = Fake.fake_user!()
        author = Fake.fake_user!()
        group = fake_group!(creator, %{membership: "open"})
        # a promoted moderator, not the creator, who could pass on being the group's creator alone
        {:ok, _} = Categories.add_moderator(creator, group, id(moderator))
        {:ok, _} = Categories.join_group(author, group)
        post = Bonfire.Classify.Simulate.fake_post_in_group!(author, group, "<p>Removable</p>")

        assert Bonfire.Social.Boosts.boosted?(group, post),
               "control: the post is in the group's feed to begin with"

        {:ok, moderator: moderator, author: author, group: group, post: post}
      end

      # taking your own post out of a group, without deleting it, needs no moderator
      test "the post's author can take it out of the group too", %{
        author: author,
        group: group,
        post: post
      } do
        refute Bonfire.Boundaries.can?(author, :mediate, group),
               "control: the author doesn't moderate the group, so the removal below is theirs as author"

        assert {:ok, _} = Categories.remove_post_from_group(author, id(group), id(post))
        refute Bonfire.Social.Boosts.boosted?(group, post)
      end

      test "a moderator takes the post out of the group, by id as the UI sends it", %{
        moderator: moderator,
        group: group,
        post: post
      } do
        assert {:ok, _} = Categories.remove_post_from_group(moderator, id(group), id(post))
        refute Bonfire.Social.Boosts.boosted?(group, post)
      end

      # it's in the group's feed by authorship, not a boost, so there is nothing to unboost: removing it from the group deletes it, the same way `Objects:delete` does (Mayel)
      test "a post written by the group itself is deleted, having no boost to remove", %{
        moderator: moderator,
        group: group
      } do
        {:ok, post} =
          Bonfire.Posts.publish(
            current_user: group,
            post_attrs: %{post_content: %{html_body: "<p>By the group</p>"}},
            context_id: id(group),
            boundary: "public"
          )

        assert e(Bonfire.Common.Repo.maybe_preload(post, :created), :created, :creator_id, nil) ==
                 id(group),
               "control: the group wrote it"

        assert {:ok, _} = Categories.remove_post_from_group(moderator, id(group), id(post))

        assert {:error, _} = Bonfire.Common.Needles.get(id(post), skip_boundary_check: true),
               "a post the group wrote has to be deleted to leave the group"
      end

      test "someone who doesn't moderate the group is refused", %{group: group, post: post} do
        stranger = Fake.fake_user!()

        assert {:error, _} = Categories.remove_post_from_group(stranger, id(group), id(post))
        assert Bonfire.Social.Boosts.boosted?(group, post)
      end
    end
  end
end
