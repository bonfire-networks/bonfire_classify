defmodule Bonfire.Classify.Moderation.BlockRecordsTest do
  @moduledoc """
  Blocking and hiding leave a RECORD, as locking does (`lock_record_test.exs`): an activity with whoever acted as subject, the block's type as verb (`silence`, `ghost`, `block` for both at once, `hide`), the person or object as object, on a `Bonfire.Data.Social.Moderation` of its own. All written in one place, `Blocks.block/3`, which a lock goes through too. Lifting a block writes nothing; the log shows the current state.

  Who reads a record: its author for a personal one, the group's moderators for one made on a group's behalf (in the group's log, its notifications feed), instance moderators for an instance-wide one.
  """
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils
  @moduletag :backend

  import Ecto.Query
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Classify.Simulate
  alias Bonfire.Common.Repo
  import Bonfire.Me.Fake, only: [fake_user!: 0]

  setup do
    # the records with this verb on this object, found by verb and object rather than through any feed, so they prove a record exists whoever may read it
    records = fn verb, object ->
      verb_id = Bonfire.Boundaries.Verbs.get_id!(verb)

      from(a in Bonfire.Data.Social.Activity,
        where: a.object_id == ^id(object) and a.verb_id == ^verb_id
      )
      |> Repo.all()
    end

    {:ok, records: records}
  end

  describe "a personal block" do
    for type <- [:silence, :ghost, :block] do
      test "#{type} leaves one record, read by its author only", %{records: records} do
        me = fake_user!()
        them = fake_user!()
        stranger = fake_user!()

        assert {:ok, _} = Blocks.block(them, unquote(type), current_user: me)

        assert [record] = records.(unquote(type), them)
        assert record.subject_id == id(me)

        {:ok, pointable} = Bonfire.Common.Needles.get(record.id, skip_boundary_check: true)
        assert Types.object_type(pointable) == Bonfire.Data.Social.Moderation

        assert Boundaries.can?(me, :read, record.id), "the one who blocked"
        refute Boundaries.can?(them, :read, record.id), "the person blocked"
        refute Boundaries.can?(stranger, :read, record.id), "a stranger"
      end
    end

    # a "Block" is both at once, and one action: one `block` record, not a `ghost` and a `silence`
    test "blocking both at once leaves one block record, and none per half", %{records: records} do
      me = fake_user!()
      them = fake_user!()

      assert {:ok, _} = Blocks.block(them, :block, current_user: me)

      assert [_] = records.(:block, them)
      assert [] = records.(:ghost, them)
      assert [] = records.(:silence, them)
    end

    test "hiding something leaves a hide record", %{records: records} do
      me = fake_user!()
      post = Bonfire.Posts.Fake.fake_post!(fake_user!())

      assert {:ok, _} = Blocks.block(post, :hide, current_user: me)

      assert [record] = records.(:hide, post)
      assert record.subject_id == id(me)
    end

    test "lifting a block leaves no record of its own", %{records: records} do
      me = fake_user!()
      them = fake_user!()
      {:ok, _} = Blocks.block(them, :silence, current_user: me)
      assert [_] = records.(:silence, them), "control: the block left its record"

      assert {:ok, _} = Blocks.unblock(them, :silence, current_user: me)

      assert [_] = records.(:silence, them), "the block's record stays, nothing added"
    end
  end

  describe "in a group" do
    setup do
      creator = fake_user!()
      group = Simulate.fake_group!(creator)
      moderator = fake_user!()
      {:ok, _} = Bonfire.Classify.Categories.add_moderator(creator, group, id(moderator))
      member = fake_user!()
      {:ok, _} = Bonfire.Classify.Categories.add_member(creator, group, id(member))
      group = Repo.maybe_preload(group, :character)

      {:ok, group: group, moderator: moderator, member: member}
    end

    test "a ban on the group's behalf leaves a record in its log, read by its moderators", %{
      records: records,
      group: group,
      moderator: moderator,
      member: member
    } do
      banned = fake_user!()

      assert {:ok, _} =
               Blocks.block(banned, :silence, current_user: moderator, on_behalf_of: group)

      assert [record] = records.(:silence, banned)
      assert record.subject_id == id(moderator), "whoever acted, not the group"

      feed_ids =
        from(fp in Bonfire.Data.Social.FeedPublish,
          where: fp.id == ^record.id,
          select: fp.feed_id
        )
        |> Repo.all()

      assert group.character.notifications_id in feed_ids, "in the group's moderation log"
      assert Boundaries.can?(moderator, :read, record.id)
      refute Boundaries.can?(member, :read, record.id), "a member who doesn't moderate"
    end

    test "removing a post from the group leaves a hide record in its log", %{
      records: records,
      group: group,
      moderator: moderator,
      member: member
    } do
      post = Simulate.fake_post_in_group!(member, group)

      assert {:ok, _} =
               Bonfire.Classify.Categories.remove_post_from_group(moderator, group, post)

      assert [record] = records.(:hide, post)
      assert record.subject_id == id(moderator)

      feed_ids =
        from(fp in Bonfire.Data.Social.FeedPublish,
          where: fp.id == ^record.id,
          select: fp.feed_id
        )
        |> Repo.all()

      assert group.character.notifications_id in feed_ids
    end

    # moving the record into `block/3`, which a lock goes through, must not leave two
    test "a lock still leaves exactly one record", %{
      records: records,
      group: group,
      moderator: moderator,
      member: member
    } do
      post = Simulate.fake_post_in_group!(member, group)

      assert {:ok, _} = Blocks.lock(post, current_user: moderator, reason: "off topic")

      assert [_] = records.(:lock, post)
    end
  end

  test "an instance-wide block names the admin who made it, read by instance moderators", %{
    records: records
  } do
    admin = Bonfire.UI.Common.Testing.Helpers.fake_admin!(Bonfire.Me.Fake.fake_account!())
    them = fake_user!()
    stranger = fake_user!()

    assert {:ok, _} =
             Blocks.block(them, :silence, current_user: admin, scope: :instance_wide)

    assert Blocks.is_blocked?(them, :silence, :instance_wide), "control: blocked instance-wide"

    assert [record] = records.(:silence, them)
    assert record.subject_id == id(admin)
    assert Boundaries.can?(admin, :read, record.id)
    refute Boundaries.can?(stranger, :read, record.id)
  end
end
