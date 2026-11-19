if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.TopicChoicesTest do
    @moduledoc """
    The choices behind the topics modal that follows Follow or the bell on a group (`Categories.topic_choices/3`, `Categories.apply_topic_choices/4`): which topics are offered and which are already on, and applying exactly the ticked ones.
    """
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils
    @moduletag :backend

    alias Bonfire.Classify.Categories
    alias Bonfire.Classify.Simulate
    alias Bonfire.Social.Graph.Follows
    alias Bonfire.Notify.Bells

    setup do
      Process.put(:federating, false)
      owner = Bonfire.Me.Fake.fake_user!()
      me = Bonfire.Me.Fake.fake_user!()

      group =
        Simulate.fake_group!(owner, %{membership: "open", visibility: "global"})

      t1 = Simulate.fake_category!(owner, group, %{name: "Seed swap", type: :topic})
      t2 = Simulate.fake_category!(owner, group, %{name: "Tool library", type: :topic})

      %{owner: owner, me: me, group: group, t1: t1, t2: t2}
    end

    describe "follow mode" do
      test "offers the visible topics, with those already followed marked on", ctx do
        assert {:ok, _} = Follows.follow(ctx.me, ctx.t2)

        choices = Categories.topic_choices(ctx.me, ctx.group, :follow)

        assert Enum.sort(Enum.map(choices.topics, &id/1)) == Enum.sort([id(ctx.t1), id(ctx.t2)])
        assert choices.on_ids == [id(ctx.t2)]
      end

      test "applies exactly the given topics, and repeating it changes nothing", ctx do
        assert Categories.apply_topic_choices(ctx.me, ctx.group, :follow, [id(ctx.t1)])
        assert Follows.following?(ctx.me, ctx.t1)
        refute Follows.following?(ctx.me, ctx.t2)

        assert Categories.apply_topic_choices(ctx.me, ctx.group, :follow, [id(ctx.t1)])
        assert Follows.following?(ctx.me, ctx.t1)
        refute Follows.following?(ctx.me, ctx.t2)
      end

      test "skips an id that is not one of the group's visible topics", ctx do
        other = Simulate.fake_group!(ctx.owner, %{membership: "open", visibility: "global"})
        stranger = Simulate.fake_category!(ctx.owner, other, %{name: "Elsewhere", type: :topic})

        Categories.apply_topic_choices(ctx.me, ctx.group, :follow, [id(stranger), id(ctx.t1)])

        assert Follows.following?(ctx.me, ctx.t1)
        refute Follows.following?(ctx.me, stranger)
        refute Follows.following?(ctx.me, other)
      end
    end

    describe "bell mode" do
      test "offers the visible topics, with those already ringing marked on", ctx do
        {:ok, _} = Bells.enable(ctx.me, ctx.t1)

        choices = Categories.topic_choices(ctx.me, ctx.group, :bell)

        assert Enum.sort(Enum.map(choices.topics, &id/1)) == Enum.sort([id(ctx.t1), id(ctx.t2)])
        assert choices.on_ids == [id(ctx.t1)]
      end

      test "rings exactly the given topics, and repeating it changes nothing", ctx do
        assert Categories.apply_topic_choices(ctx.me, ctx.group, :bell, [id(ctx.t2)])
        assert Categories.apply_topic_choices(ctx.me, ctx.group, :bell, [id(ctx.t2)])

        assert Bells.enabled?(ctx.me, ctx.t2)
        refute Bells.enabled?(ctx.me, ctx.t1)
      end

      test "skips an id that is not one of the group's visible topics", ctx do
        other = Simulate.fake_group!(ctx.owner, %{membership: "open", visibility: "global"})

        Categories.apply_topic_choices(ctx.me, ctx.group, :bell, [id(other), id(ctx.t1)])

        assert Bells.enabled?(ctx.me, ctx.t1)
        refute Bells.enabled?(ctx.me, other)
      end

      # a mirrored topic's posts only arrive through a follow, so it is listed but marked as needing one first
      test "lists a mirrored topic the person does not follow as needing a follow", ctx do
        assert {:ok, _} =
                 Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(
                   ctx.t2,
                   "https://elsewhere.local/c/tools"
                 )

        choices = Categories.topic_choices(ctx.me, ctx.group, :bell)

        assert Enum.sort(Enum.map(choices.topics, &id/1)) == Enum.sort([id(ctx.t1), id(ctx.t2)])
        assert choices.needs_follow_ids == [id(ctx.t2)]
      end

      test "refuses to ring a mirrored topic that is neither followed nor requested", ctx do
        assert {:ok, _} =
                 Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(
                   ctx.t2,
                   "https://elsewhere.local/c/tools"
                 )

        Categories.apply_topic_choices(ctx.me, ctx.group, :bell, [id(ctx.t1), id(ctx.t2)])

        assert Bells.enabled?(ctx.me, ctx.t1)
        refute Bells.enabled?(ctx.me, ctx.t2)

        # once the follow has been asked for (the remote's Accept may still be pending), it can be rung
        assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(ctx.me, ctx.t2)

        assert Categories.topic_choices(ctx.me, ctx.group, :bell).needs_follow_ids == []
        Categories.apply_topic_choices(ctx.me, ctx.group, :bell, [id(ctx.t2)])
        assert Bells.enabled?(ctx.me, ctx.t2)
      end
    end

    describe "stop modes" do
      test "unfollow lists only the topics you follow, and unfollows the given ones", ctx do
        assert {:ok, _} = Follows.follow(ctx.me, ctx.t1)

        assert Enum.map(Categories.topic_choices(ctx.me, ctx.group, :unfollow).topics, &id/1) ==
                 [id(ctx.t1)]

        Categories.apply_topic_choices(ctx.me, ctx.group, :unfollow, [id(ctx.t1)])
        refute Follows.following?(ctx.me, ctx.t1)
      end

      test "unbell lists only the topics you have belled, and stops the given ones", ctx do
        {:ok, _} = Bells.enable(ctx.me, ctx.t2)

        assert Enum.map(Categories.topic_choices(ctx.me, ctx.group, :unbell).topics, &id/1) ==
                 [id(ctx.t2)]

        Categories.apply_topic_choices(ctx.me, ctx.group, :unbell, [id(ctx.t2)])
        refute Bells.enabled?(ctx.me, ctx.t2)
      end
    end

    # the modal a moderator gets after saving the group's boundary settings: the ticked topics get the group's new boundaries
    describe "boundaries mode" do
      defp go_members_only(ctx) do
        assert :ok =
                 Bonfire.Classify.Boundaries.apply_changes(ctx.group, ctx.owner, %{
                   dims: %{membership: "invite_only", visibility: "members:private"}
                 })
      end

      test "offers every direct topic of the group", ctx do
        choices = Categories.topic_choices(ctx.owner, ctx.group, :boundaries)

        assert Enum.sort(Enum.map(choices.topics, &id/1)) == Enum.sort([id(ctx.t1), id(ctx.t2)])
        assert choices.on_ids == []
        assert choices.needs_follow_ids == []
      end

      test "applies the group's boundaries to the ticked topics only", ctx do
        assert Bonfire.Boundaries.can?(ctx.me, :read, ctx.t1), "control: readable to begin with"
        assert Bonfire.Boundaries.can?(ctx.me, :read, ctx.t2), "control: readable to begin with"

        go_members_only(ctx)

        assert {:ok, ids} =
                 Categories.apply_topic_choices(ctx.owner, ctx.group, :boundaries, [id(ctx.t1)])

        assert ids == [id(ctx.t1)]

        refute Bonfire.Boundaries.can?(ctx.me, :read, ctx.t1),
               "the ticked topic follows the group"

        assert Bonfire.Boundaries.can?(ctx.me, :read, ctx.t2),
               "the unticked topic keeps its old visibility"
      end

      test "repeating it changes nothing", ctx do
        go_members_only(ctx)

        for _ <- 1..2 do
          assert {:ok, _} =
                   Categories.apply_topic_choices(ctx.owner, ctx.group, :boundaries, [id(ctx.t1)])
        end

        refute Bonfire.Boundaries.can?(ctx.me, :read, ctx.t1)
      end

      test "someone who does not manage the group is refused", ctx do
        go_members_only(ctx)

        assert {:error, :unauthorized} =
                 Categories.apply_topic_choices(ctx.me, ctx.group, :boundaries, [id(ctx.t1)])

        assert Bonfire.Boundaries.can?(ctx.me, :read, ctx.t1), "and nothing was applied"
      end
    end

    test "a group with no topics has no choices", ctx do
      empty = Simulate.fake_group!(ctx.owner, %{membership: "open", visibility: "global"})

      assert Categories.topic_choices(ctx.me, empty, :follow).topics == []
    end
  end
end
