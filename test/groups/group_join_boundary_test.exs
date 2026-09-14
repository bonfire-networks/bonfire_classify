if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupJoinBoundaryTest do
    @moduledoc """
    Who may JOIN a group is a boundary question, answered by the `:join` verb.

    Joining and following are gated by different dimensions: following by the group's VISIBILITY (may this actor see and read it), joining by its MEMBERSHIP (open / on_request / invite_only). The `:join` verb is what carries the second, and it is granted positively — an ACL that says who may join — rather than by revoking something broader, so nothing has to be taken back to express a narrower rule.

    That positive-only shape is why `on_request` needs no negative grant of its own: it simply does not grant `:join`, and grants `:request` instead, so someone can ask. `invite_only` grants neither, which is the same "no" one step firmer.
    """
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils

    alias Bonfire.Classify.Simulate
    alias Bonfire.Me.Fake

    setup do
      # nothing here federates; publishing/boundary changes otherwise spawn federation tasks with no DB ownership in tests
      Process.put(:federating, false)

      :ok
    end

    defp group_with(creator, membership) do
      group = Simulate.fake_group!(creator, %{type: :group})

      :ok =
        Bonfire.Classify.Boundaries.apply(group, creator, %{
          membership: membership,
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      group
    end

    test "an open group grants :join" do
      creator = Fake.fake_user!()
      joiner = Fake.fake_user!()

      group = group_with(creator, "open")

      assert Bonfire.Boundaries.can?(joiner, :join, group) == true,
             "an open group is one anybody may walk into, which is what the verb has to say"
    end

    test "a group that reviews joins does not grant :join, but does grant :request" do
      creator = Fake.fake_user!()
      joiner = Fake.fake_user!()

      group = group_with(creator, "on_request")

      refute Bonfire.Boundaries.can?(joiner, :join, group) == true,
             "if this granted `:join`, approval would be decided by whoever wrote the join code rather than by the boundary"

      assert Bonfire.Boundaries.can?(joiner, :request, group) == true,
             "the point of `on_request` is that asking is allowed, which is a different verb from joining"
    end

    test "an invite-only group grants neither" do
      creator = Fake.fake_user!()
      joiner = Fake.fake_user!()

      group = group_with(creator, "invite_only")

      refute Bonfire.Boundaries.can?(joiner, :join, group) == true

      refute Bonfire.Boundaries.can?(joiner, :request, group) == true,
             "invite-only means the answer is no and asking will not change it, so the ask should not be offered either"
    end
  end
end
