defmodule Bonfire.Classify.GroupModeratorsAclTest do
  @moduledoc """
  A group's moderators reach what is published in it through ONE ACL per group, a stereotype like each user's `i_may_administer`, granting its moderators circle the `:moderate` role. Attaching a shared ACL rather than granting on each post keeps the database from gaining a custom ACL and grant rows per post, and promoting or demoting a moderator changes the circle and nothing per post.
  """
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils
  @moduletag :backend

  alias Bonfire.Boundaries.Scaffold.Groups, as: ScaffoldGroups
  alias Bonfire.Classify.Simulate
  import Bonfire.Me.Fake, only: [fake_user!: 0]

  # the rows themselves: the grants listing API expects a person as `current_user`, and here the caretaker is the group
  defp grants_of(acl) do
    import Ecto.Query

    from(g in Bonfire.Data.AccessControl.Grant, where: g.acl_id == ^id(acl))
    |> Bonfire.Common.Repo.all()
  end

  test "a new group gets an ACL granting its moderators circle the moderate role" do
    group = Simulate.fake_group!(fake_user!())

    assert {:ok, acl} = ScaffoldGroups.moderators_acl(group)
    {:ok, circle} = ScaffoldGroups.moderators_circle(group)

    mediate = Bonfire.Boundaries.Verbs.get_id!(:mediate)

    assert Enum.any?(
             grants_of(acl),
             &(&1.subject_id == id(circle) and &1.verb_id == mediate and &1.value == true)
           ),
           "the moderate role includes :mediate"
  end

  test "asking for it again returns the same ACL rather than creating another" do
    group = Simulate.fake_group!(fake_user!())

    assert {:ok, acl} = ScaffoldGroups.moderators_acl(group)
    assert {:ok, again} = ScaffoldGroups.moderators_acl(group)
    assert id(again) == id(acl)
  end

  describe "what is published in a group" do
    setup do
      creator = fake_user!()
      group = Simulate.fake_group!(creator)
      moderator = fake_user!()
      {:ok, _} = Bonfire.Classify.Categories.add_moderator(creator, group, id(moderator))

      # members, since only they may post in the group: someone who may not is never published INTO it. `other` is also the control for "not by anyone else", a member who is not a moderator
      author = fake_user!()
      other = fake_user!()
      {:ok, _} = Bonfire.Classify.Categories.add_member(creator, group, id(author))
      {:ok, _} = Bonfire.Classify.Categories.add_member(creator, group, id(other))

      %{group: group, creator: creator, moderator: moderator, author: author, other: other}
    end

    defp mediate?(user, object), do: Bonfire.Boundaries.can?(user, :mediate, object)

    test "a post published in it can be moderated by its moderators, and not by anyone else", %{
      group: group,
      moderator: moderator,
      author: author,
      other: other
    } do
      post = Simulate.fake_post_in_group!(author, group)

      {:ok, acl} = ScaffoldGroups.moderators_acl(group)

      assert id(acl) in Enum.map(Bonfire.Boundaries.Controlleds.list_on_object(post), & &1.acl_id),
             "control: the post carries the group's moderators ACL, so a refusal below is the ACL not granting rather than it never being attached"

      assert mediate?(moderator, post)
      refute mediate?(other, post), "only moderators: the ACL must not open the post to everyone"
    end

    # how API clients and federated posts arrive, with none of the composer's `to_circles`
    test "the same for a post published with `publish_in` alone", %{
      group: group,
      moderator: moderator,
      author: author
    } do
      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: author,
                 post_attrs: %{post_content: %{html_body: "<p>via the API</p>"}},
                 boundary: "public",
                 publish_in: uid(group)
               )

      assert mediate?(moderator, post)
    end

    test "a reply in its thread can be moderated by its moderators, since the reply belongs to the group too",
         %{group: group, moderator: moderator, author: author, other: other} do
      post = Simulate.fake_post_in_group!(author, group)

      assert {:ok, reply} =
               Bonfire.Posts.publish(
                 current_user: other,
                 post_attrs: %{
                   post_content: %{html_body: "<p>a reply</p>"},
                   reply_to_id: id(post)
                 },
                 boundary: "public"
               )

      assert mediate?(moderator, reply)
    end

    # what a group sends in its own name, such as a remote community's moderation, passes the same verb checks as anyone else's, rather than being accepted for coming from the group's host
    test "the group itself can moderate what is published in it", %{group: group, author: author} do
      post = Simulate.fake_post_in_group!(author, group)

      assert mediate?(group, post)
    end

    # what the ACL is for: closing a member's thread, which a moderator could not do before
    test "a moderator can lock a post published in it, and a member who is not one cannot", %{
      group: group,
      moderator: moderator,
      author: author,
      other: other
    } do
      post = Simulate.fake_post_in_group!(author, group)

      assert {:error, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: other)
      assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: moderator)
      refute Bonfire.Boundaries.can?(other, :reply, post), "the thread is closed"
    end

    test "someone no longer a moderator can no longer moderate it", %{
      group: group,
      creator: creator,
      moderator: moderator,
      author: author
    } do
      post = Simulate.fake_post_in_group!(author, group)
      assert mediate?(moderator, post), "control: they could while a moderator"

      {:ok, _} = Bonfire.Classify.Categories.remove_moderator(creator, group, id(moderator))

      refute mediate?(moderator, post)
    end
  end

  # as a user administers their own account through `i_may_administer`
  test "a group administers itself, and not another group" do
    creator = fake_user!()
    group = Simulate.fake_group!(creator)
    other_group = Simulate.fake_group!(creator)

    assert Bonfire.Boundaries.can?(group, :grant, group)
    refute Bonfire.Boundaries.can?(other_group, :grant, group)
  end

  test "each group has its own" do
    creator = fake_user!()

    {:ok, one} = ScaffoldGroups.moderators_acl(Simulate.fake_group!(creator))
    {:ok, other} = ScaffoldGroups.moderators_acl(Simulate.fake_group!(creator))

    refute id(one) == id(other)
  end
end
