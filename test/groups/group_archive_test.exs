if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupArchiveTest do
    @moduledoc """
    An archived group takes no new contributions.

    Archiving (`Categories.soft_delete/2`) withdraws the group: it unindexes it, sets `deleted_at`, and is undone by `unarchive/2`. What `deleted_at` alone does not guarantee is that nothing can still be posted into it, since that depends on every path filtering the flag, including the ones remote deliveries take. So archiving also locks the group, with the same `:lock` block a closed thread uses, and unarchiving lifts it.

    A lock rather than a dimension change, deliberately: it says exactly "no more participation" (where `participation: "moderators"` would still let moderators post into a frozen group), and it leaves the group's dimensions untouched, so unarchiving restores what was there rather than needing the previous dimensions stashed somewhere.
    """
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils

    alias Bonfire.Classify.Categories
    alias Bonfire.Classify.Simulate
    alias Bonfire.Me.Fake

    setup do
      # publishing into a group spawns federation tasks, which have no DB ownership in tests, the same reason `groups_test.exs` does this. Nothing here is about federating
      Process.put(:federating, false)

      :ok
    end

    defp open_group!(creator) do
      Simulate.fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })
    end

    test "an archived group takes no new posts" do
      creator = Fake.fake_user!()
      group = open_group!(creator)

      before = Simulate.fake_post_in_group!(creator, group, "<p>while it was open</p>")

      assert Bonfire.Social.Boosts.boosted?(group, before),
             "control: an open group boosts what is published into it, so the refutation below means something"

      assert {:ok, _} = Categories.soft_delete(group, creator)

      after_archive = Simulate.fake_post_in_group!(creator, group, "<p>after archiving</p>")

      refute Bonfire.Social.Boosts.boosted?(group, after_archive),
             "an archived group that still accepts contributions is only archived in the listings, not in fact"
    end

    # What a lock looks like from each angle, because a caller reporting the group's state to other instances (`postingRestrictedToMods`) has no particular member in hand and has to ask SOMETHING. A member is denied because they are also in the local/activity_pub circles the lock denies, and negative grants win; the open question these pin down is whether asking about the members CIRCLE sees that too, or only reports the grant that circle holds.
    describe "how a lock reads back" do
      test "a member cannot post in an archived group" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = open_group!(creator)
        assert {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)

        assert Bonfire.Boundaries.can?(member, :tag, group),
               "control: a member of an open group may post in it"

        assert {:ok, _} = Categories.soft_delete(group, creator)

        refute Bonfire.Boundaries.can?(member, :tag, group),
               "the lock denies local and activity_pub, and members are in those, so a member is denied too"
      end

      # ⚠️ A circle is not one of its members: asking about the members CIRCLE answers false even for an open group, since "anyone" participation grants the local and activity_pub circles rather than that one. The grant a remote actor's post relies on belongs to `activity_pub`, so that is the subject to ask about when there is no particular member in hand.
      test "asking about the activity_pub circle sees the lock" do
        creator = Fake.fake_user!()
        group = open_group!(creator)

        assert Bonfire.Boundaries.can?(:activity_pub, :tag, group) == true,
               "control: an open group lets remote actors post into it, which is what makes the assertion below meaningful"

        assert {:ok, _} = Categories.soft_delete(group, creator)

        assert Bonfire.Boundaries.can?(:activity_pub, :tag, group) == false,
               "a locked group closes to remote actors too, which is what its actor needs to declare"
      end

      # The conflation to know about before using that check as a wire signal: a group only its MEMBERS may post in reads exactly like a locked one, because the grant belongs to the members circle rather than to `activity_pub`.
      test "a members-only group reads the same as a locked one" do
        creator = Fake.fake_user!()

        members_only =
          Simulate.fake_group!(creator, %{
            membership: "open",
            visibility: "global",
            participation: "group_members",
            default_content_visibility: "public"
          })

        assert Bonfire.Boundaries.can?(:activity_pub, :tag, members_only) == false
      end
    end

    test "unarchiving opens it again" do
      creator = Fake.fake_user!()
      group = open_group!(creator)

      assert {:ok, _} = Categories.soft_delete(group, creator)
      assert {:ok, group} = Categories.unarchive(group, creator)

      post = Simulate.fake_post_in_group!(creator, group, "<p>back in business</p>")

      assert Bonfire.Social.Boosts.boosted?(group, post),
             "archiving is reversible, so whatever closed the group has to be lifted with it"
    end
  end
end
