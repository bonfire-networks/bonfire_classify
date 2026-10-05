defmodule Bonfire.Classify.Moderation.LockRecordTest do
  @moduledoc """
  A moderation action leaves a RECORD: an activity with whoever acted as subject, the action as verb, the target as object, and the reason in a `named` mixin, on a `Bonfire.Data.Social.Moderation` pointable of its own. Locking a thread is the first action to write one.
  """
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils
  @moduletag :backend

  import Ecto.Query
  alias Bonfire.Classify.Simulate
  alias Bonfire.Common.Repo
  import Bonfire.Me.Fake, only: [fake_user!: 0]

  # the lock activity on this post, found by verb and object rather than through any feed, so it proves the record exists whoever may read it
  defp lock_activity(post) do
    from(a in Bonfire.Data.Social.Activity,
      where: a.object_id == ^id(post) and a.verb_id == ^Bonfire.Boundaries.Verbs.get_id!(:lock)
    )
    |> Repo.one()
  end

  setup do
    creator = fake_user!()
    group = Simulate.fake_group!(creator)
    # a promoted moderator, not the creator, who could pass on being the group's creator alone
    moderator = fake_user!()
    {:ok, _} = Bonfire.Classify.Categories.add_moderator(creator, group, id(moderator))

    author = fake_user!()
    {:ok, _} = Bonfire.Classify.Categories.add_member(creator, group, id(author))
    post = Simulate.fake_post_in_group!(author, group)

    %{group: group, creator: creator, moderator: moderator, author: author, post: post}
  end

  test "a moderator's lock with a reason leaves a record of who, what and why", %{
    moderator: moderator,
    post: post
  } do
    assert {:ok, _} =
             Bonfire.Boundaries.Blocks.lock(post, current_user: moderator, reason: "off topic")

    assert %{} = activity = lock_activity(post), "the lock left no activity"
    assert activity.subject_id == id(moderator)

    {:ok, record} = Bonfire.Common.Needles.get(activity.id, skip_boundary_check: true)

    assert Types.object_type(record) == Bonfire.Data.Social.Moderation,
           "the activity is on a record of its own, not on the post"

    assert e(Repo.maybe_preload(record, :named), :named, :name, nil) == "off topic"
  end

  test "a lock without a reason still leaves a record, with no reason", %{
    moderator: moderator,
    post: post
  } do
    assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: moderator)

    assert %{} = activity = lock_activity(post), "the lock left no activity"
    {:ok, record} = Bonfire.Common.Needles.get(activity.id, skip_boundary_check: true)
    assert Types.object_type(record) == Bonfire.Data.Social.Moderation
    assert is_nil(e(Repo.maybe_preload(record, :named), :named, :name, nil))
  end

  test "a refused lock leaves no record", %{moderator: moderator, post: post} do
    stranger = fake_user!()

    assert {:error, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: stranger)
    refute lock_activity(post), "a refused lock left a record"

    # the same query finds a record once a lock is allowed, so "none" above means refused rather than never found
    assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: moderator)
    assert %{} = lock_activity(post), "control: an allowed lock is found by the same query"
  end

  # not public like Lemmy's modlog: by default only the group's moderators read a record of an action taken in it
  test "only the group's moderators can read the record", %{
    creator: creator,
    moderator: moderator,
    author: author,
    post: post
  } do
    stranger = fake_user!()

    assert {:ok, _} =
             Bonfire.Boundaries.Blocks.lock(post, current_user: moderator, reason: "off topic")

    record_id = lock_activity(post).id

    assert Bonfire.Boundaries.can?(moderator, :read, record_id), "the moderator who acted"
    assert Bonfire.Boundaries.can?(creator, :read, record_id), "the group's creator"
    refute Bonfire.Boundaries.can?(author, :read, record_id), "a member (here, the post's author)"
    refute Bonfire.Boundaries.can?(stranger, :read, record_id), "a stranger"
  end

  # the group's log is its notifications feed, where its moderators already find flags and join requests; NOT its outbox, which is the group's public timeline
  test "the record is published to the group's notifications, not its outbox", %{
    group: group,
    moderator: moderator,
    post: post
  } do
    assert {:ok, _} =
             Bonfire.Boundaries.Blocks.lock(post, current_user: moderator, reason: "off topic")

    record_id = lock_activity(post).id
    group = Repo.maybe_preload(group, :character)

    feed_ids =
      from(fp in Bonfire.Data.Social.FeedPublish, where: fp.id == ^record_id, select: fp.feed_id)
      |> Repo.all()

    assert group.character.notifications_id in feed_ids, "not in the group's moderation log"
    refute group.character.outbox_id in feed_ids, "on the group's public timeline"
  end
end
