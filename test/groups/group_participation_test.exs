defmodule Bonfire.Classify.GroupParticipationTest do
  use Bonfire.Classify.DataCase, async: true

  alias Bonfire.Classify.Categories
  alias Bonfire.Me.Fake
  alias Bonfire.Social.Graph.Follows

  setup do
    Process.put(:federating, false)
    creator = Fake.fake_user!()
    user = Fake.fake_user!()
    {:ok, user: user, creator: creator}
  end

  test "announcement followers cannot turn their follow into membership", %{user: user, creator: creator} do
    group = fake_group!(creator, %{membership: "invite_only", visibility: "global", participation: "moderators"})
    assert {:ok, _} = Follows.follow(user, group)
    assert {:error, :invite_only} = Categories.join_group(user, group.id)
    refute Map.get(Categories.member_of_groups?(user, [group.id]), group.id, false)
    assert Follows.following?(user, group)
  end

  test "former members who still follow need approval to rejoin", %{user: user, creator: creator} do
    group = fake_group!(creator, %{membership: "on_request", visibility: "global"})
    assert {:ok, %{requested: true}} = Categories.join_group(user, group)
    assert {:ok, request} = Bonfire.Social.Requests.get(user, Bonfire.Data.Social.Follow, group, current_user: creator)
    assert {:ok, _} = Categories.accept_join_request(creator, request)
    assert Follows.following?(user, group)
    assert {:ok, _} = Categories.leave_group(user, group.id)
    assert Follows.following?(user, group)

    assert {:error, :approval_required} = Categories.join_group(user, group.id)
    refute Map.get(Categories.member_of_groups?(user, [group.id]), group.id, false)
    assert Follows.following?(user, group)
    refute Follows.requested?(user, group)

  end

  test "approval requests can be cancelled without granting membership", %{user: user, creator: creator} do
    group = fake_group!(creator, %{membership: "on_request", visibility: "global"})
    assert {:ok, %{requested: true, member: false}} = Categories.join_group(user, group.id)
    assert Follows.requested?(user, group)
    Follows.unfollow(user, group.id)
    refute Follows.requested?(user, group)
  end

end
