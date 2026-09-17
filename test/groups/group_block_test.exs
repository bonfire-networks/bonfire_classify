if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupBlockTest do
    @moduledoc """
    What blocking a group does, and what it deliberately does not.

    A group is an actor with a character of its own, so it can be blocked like anyone else. The two halves point in opposite directions and are worth keeping straight, since the names invite the wrong reading:

    - GHOSTING is "people I ghosted cannot see me". It writes the blocker's own `ghost_them` circle, and `ghosted_cannot_anything` on the blocker's objects does the rest, so the GROUP stops reaching them. It does not hide the group.
    - SILENCING is the half that hides the group FROM the blocker. It keeps a reverse index on the thing being silenced, adding the blocker to the GROUP's own `silence_me` circle, which the group's `my_cannot_discover_if_silenced` denies `:see` to. The group then drops out of anything boundarised on `:see`, listings included.

    Both are per-user: nobody else's view changes.

    The rule throughout is that silencing hides what the silenced actor CARETAKES, which is usually but not always what it authored: the boundary query joins on `Caretaker`, and `apply_slugs/4` for instance hands a group's own ACLs to the group as caretaker. So the same rule covers anything a group authors itself, whether written here or received from a remote with the group as author. It does not cover a member's post the group merely relayed, since that belongs to its author and nobody silenced them.

    Whether it SHOULD is open, and the two routes differ in what else they settle: attaching the group's denial to posts published in it (additive, and `Controlled` is already multi), or giving a post more than one caretaker (which forces a decision about what deleting a group does to member posts). See the group federation plan.

    Severing follows is opt-in (`also_unfollow_and_notify`), because doing it unasked tells the other side they were blocked, and unblocking never restores it. The same opt-in emits the `Block`, since both reach past our own instance and both are noticeable.

    Categories are not scaffolded with block boundaries at signup the way users are: they get them the first time somebody blocks them, through `Scaffold.create_missing_block_boundaries/2`.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Me.Fake
    alias Bonfire.Boundaries
    alias Bonfire.Boundaries.Blocks

    setup do
      Process.put(:federating, false)
      :ok
    end

    defp visible_group do
      creator = Fake.fake_user!()
      user = Fake.fake_user!()
      group = fake_group!(creator, %{name: "Loud Group", visibility: "nonfederated"})

      assert Boundaries.can?(user, :see, group),
             "the control: the group is visible before any block, so a refusal below is the block rather than the fixture"

      {user, group}
    end

    # Works today, and note which way it points: `ghost_them` is named "People I ghosted cannot see me", so ghosting stops the GROUP reaching the user's things. It does not hide the group from the user, which is the silence half's job.
    test "ghosting a group stops the group seeing the blocker" do
      {user, group} = visible_group()

      assert Boundaries.can?(group, :see, user),
             "the control: the group can see them before the ghost"

      assert {:ok, _} = Blocks.block(group, :ghost, current_user: user)

      refute Boundaries.can?(group, :see, user)

      assert Boundaries.can?(user, :see, group),
             "and deliberately not the other way: hiding the group from the user is what silencing does"
    end

    # The boundary half. `Categories.list/2` boundarises on `verbs: [:see]`, so a group the viewer has silenced drops out of the listing for them and stays for everyone else, which is what silencing an actor means.
    test "a silenced group disappears from the blocker's group listing" do
      creator = Fake.fake_user!()
      user = Fake.fake_user!()
      other = Fake.fake_user!()
      group = fake_group!(creator, %{name: "Loud Group", visibility: "nonfederated"})

      assert listed?(group, user),
             "the control: the group is listed before the block, so the absence below is the block rather than the fixture"

      assert {:ok, _} = Blocks.block(group, :silence, current_user: user)

      refute listed?(group, user)

      assert listed?(group, other),
             "and only for them: silencing is per-user, so everybody else still sees the group"
    end

    defp listed?(group, viewer) do
      Bonfire.Classify.Categories.list([:default, type: :group], current_user: viewer)
      |> e(:edges, [])
      |> Enum.any?(&(id(&1) == id(group)))
    end

    # Severing the follow is opt-in, because it tells the group's side that they were blocked, and `unblock/3` never restores it. Asked for explicitly here, and the feed emptying is a consequence of the SUBSCRIPTION going rather than of anything being denied, which is why the unfollow is asserted alongside it.
    # Published with `publish_in:`, which is what actually puts a post into a group. Addressing it via `to_circles` names the group as an audience without the group relaying anything, so nothing fans out to followers and the control fails for an unrelated reason.
    test "silencing a group with also_unfollow_and_notify drops the subscription, so its posts stop arriving" do
      creator = Fake.fake_user!()
      user = Fake.fake_user!()
      group = fake_group!(creator, %{name: "Loud Group", visibility: "nonfederated"})

      assert {:ok, _} =
               Bonfire.Classify.Categories.follow_group(user, group, skip_boundary_check: true)

      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: creator,
                 post_attrs: %{post_content: %{html_body: "<p>noise from the group</p>"}},
                 boundary: "public",
                 publish_in: uid(group)
               )

      assert Bonfire.Social.FeedLoader.feed_contains?(:my, post, current_user: user),
             "the control: following a group is what delivers its posts, so the refusal below is the block rather than the fixture"

      assert {:ok, _} =
               Blocks.block(group, :silence,
                 current_user: user,
                 also_unfollow_and_notify: true
               )

      refute Bonfire.Social.Graph.Follows.following?(user, group),
             "the mechanism: the opt severs the follow, and that is the whole reason the feed below is empty"

      refute Bonfire.Social.FeedLoader.feed_contains?(:my, post, current_user: user)
    end

    # ⚠️ The unfollow above is a privacy problem in its own right, not just a confusing mechanism: silencing is a MUTE, meant to be invisible to its target, but dropping their follower count and leaving their followers list tells them. Ghosting unfollows in the other direction (`Follows.unfollow(them, me)`) where a visible block is at least defensible. See the group federation plan; the fix is for the unfollow to be optional, which the boundary denial working is what makes possible.
  end
end
