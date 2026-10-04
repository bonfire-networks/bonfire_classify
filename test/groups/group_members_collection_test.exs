if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupMembersCollectionTest do
    @moduledoc """
    A group declares a `members` collection, as Mobilizon and Smithereen do and the threadiverse doesn't. Declaring one is how a remote server tells that membership here is not the same as following, so it waits for our answer to a `Join` rather than taking our answer to a `Follow` as settling it.

    Every group declares it, whatever its visibility, since the URI says nothing about who is in it. What it SERVES follows the group's visibility, by the rule that decides whether the moderators collection is declared (`group_moderators_collection_test.exs`): a hidden group serves none.
    """
    use Bonfire.Classify.ConnCase, async: false
    use Bonfire.Common.Utils
    @moduletag :backend

    alias Bonfire.Classify.Categories

    defp group_with(creator, dims) do
      group = fake_group!(creator)
      assert :ok = Bonfire.Classify.Boundaries.replace(group, creator, dims)
      {:ok, group} = Categories.get(id(group), skip_boundary_check: true)
      group
    end

    defp public_group(creator),
      do:
        group_with(creator, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

    defp hidden_group(creator),
      do:
        group_with(creator, %{
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members",
          default_content_visibility: "members:private"
        })

    defp served_members(group) do
      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/collections/members/#{id(group)}")

      json_response(conn, 200)
    end

    # paged, unlike the moderators one, since a group can have many members: the first page is embedded
    defp items(served), do: get_in(served, ["first", "items"]) || []

    test "a group's actor points at its members collection" do
      group = public_group(Bonfire.Me.Fake.fake_user!())

      assert %{data: data} = Categories.format_actor(group)
      assert data["members"] == ActivityPub.Utils.collection_ap_id("members", id(group))
    end

    test "the collection lists the group's members" do
      creator = Bonfire.Me.Fake.fake_user!()
      member = Bonfire.Me.Fake.fake_user!()
      group = public_group(creator)
      assert {:ok, _} = Categories.join_group(member, group)

      served = served_members(group)

      assert Enum.any?(items(served), &String.contains?(&1, id(member))),
             "Got: #{inspect(served)}"
    end

    # the pair of the test above, for a hidden group (`members:private` visibility, not federated yet): the URI is declared all the same, since it says nothing about who is in it
    test "a hidden group declares the collection but serves no members" do
      creator = Bonfire.Me.Fake.fake_user!()
      member = Bonfire.Me.Fake.fake_user!()
      group = hidden_group(creator)

      # an invite-only group refuses `join_group/3`, so straight into the circle, as accepting an invite does
      {:ok, circle} = Categories.members_circle(group)
      Bonfire.Boundaries.Circles.add_to_circles(member, [circle])
      assert Categories.member?(member, group), "nobody joined, so this test proves nothing"

      assert %{data: data} = Categories.format_actor(group)
      assert data["members"] == ActivityPub.Utils.collection_ap_id("members", id(group))

      served = served_members(group)

      refute Enum.any?(items(served), &String.contains?(&1, id(member))),
             "the wire must not say more than the web does. Got: #{inspect(served)}"

      assert served["totalItems"] in [0, nil]
    end
  end
end
