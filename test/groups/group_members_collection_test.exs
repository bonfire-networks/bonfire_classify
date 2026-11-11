if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupMembersCollectionTest do
    @moduledoc """
    A group declares a `members` collection, as Mobilizon and Smithereen do and the threadiverse doesn't. Declaring one is how a remote server tells that membership here is not the same as following, so it waits for our answer to a `Join` rather than taking our answer to a `Follow` as settling it.

    Every group declares it, whatever its visibility, since the URI says nothing about who is in it. What it SERVES follows the group's visibility, by the rule that decides whether the moderators collection is declared (`group_moderators_collection_test.exs`): a hidden group serves none.
    """
    use Bonfire.Classify.ConnCase, async: false
    use Bonfire.Common.Utils

    # these tests check what a group serves, not who may fetch it (that is `signed_fetch_public_actors_test.exs`), so they fetch unsigned, with signed fetches not required; with them required, a refusal here could be the signature's rather than the group's
    setup do
      previous = Application.get_env(:activity_pub, :reject_unsigned)
      Application.put_env(:activity_pub, :reject_unsigned, false)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:activity_pub, :reject_unsigned),
          else: Application.put_env(:activity_pub, :reject_unsigned, previous)
      end)
    end

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

    # visible to everyone, but joining needs approval or an invite
    defp closed_group(creator, membership),
      do:
        group_with(creator, %{
          membership: membership,
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

    defp served_members(group, query \\ "") do
      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/collections/members/#{id(group)}#{query}")

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

    # Who is in a group is part of what admission protects where joining needs approval or an invite (`Categories.roster_audience/1`), so the collection says how many and not who. Not an empty page, which would link on to empty pages
    for membership <- ["on_request", "invite_only"] do
      test "a #{membership} group serves how many members it has and not who they are" do
        creator = Bonfire.Me.Fake.fake_user!()
        member = Bonfire.Me.Fake.fake_user!()
        group = closed_group(creator, unquote(membership))

        {:ok, circle} = Categories.members_circle(group)
        Bonfire.Boundaries.Circles.add_to_circles(member, [circle])
        assert Categories.member?(member, group), "nobody joined, so this test proves nothing"

        count = Bonfire.Boundaries.Circles.count_members(circle)
        assert count >= 1

        for query <- ["", "?page=1", "?page=2"] do
          served = served_members(group, query)

          assert served["totalItems"] == count, "Got: #{inspect(served)}"
          refute Map.has_key?(served, "first"), "#{query}: Got: #{inspect(served)}"
          refute Map.has_key?(served, "next"), "#{query}: Got: #{inspect(served)}"
          assert items(served) == []
          assert (served["orderedItems"] || served["items"] || []) == [], "#{query}"
        end
      end
    end

    # A member of a group elsewhere reads the group's members as Mobilizon's members do, and that is how a mirror of a group of ours copies its list: signed as a member, the collection lists them. Signature verification is faked as the fork's controller tests do (a `valid_signature` assign and a `keyId` header)
    describe "to a requester signed as" do
      @member "https://signer.local/users/member"
      @stranger "https://signer.local/users/stranger"

      setup do
        Tesla.Mock.mock_global(fn
          %{method: :get, url: url} when url in [@member, @stranger] ->
            Tesla.Mock.json(
              Bonfire.Federate.ActivityPub.Simulate.actor_json(url, Path.basename(url))
            )
        end)

        :ok
      end

      defp served_members_as(group, signer) do
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> assign(:valid_signature, true)
        |> put_req_header("signature", "keyId=\"#{signer}\"")
        |> get("/pub/collections/members/#{id(group)}")
        |> json_response(200)
      end

      test "a member of a group joined by request, its members are listed" do
        group = closed_group(Bonfire.Me.Fake.fake_user!(), "on_request")

        {:ok, member} =
          Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(@member)

        {:ok, circle} = Categories.members_circle(group)
        Bonfire.Boundaries.Circles.add_to_circles(member, [circle])
        assert Categories.member?(member, group), "nobody joined, so this test proves nothing"

        served = served_members_as(group, @member)

        assert @member in items(served), "Got: #{inspect(served)}"
      end

      test "someone who is not a member, only how many there are" do
        group = closed_group(Bonfire.Me.Fake.fake_user!(), "on_request")

        {:ok, _} =
          Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(@stranger)

        {:ok, circle} = Categories.members_circle(group)

        served = served_members_as(group, @stranger)

        assert served["totalItems"] == Bonfire.Boundaries.Circles.count_members(circle)
        refute Map.has_key?(served, "first"), "Got: #{inspect(served)}"
        assert items(served) == []
      end
    end

    test "a group's actor states how many members it has" do
      creator = Bonfire.Me.Fake.fake_user!()
      group = public_group(creator)
      assert {:ok, _} = Categories.join_group(Bonfire.Me.Fake.fake_user!(), group)

      assert %{data: data} = Categories.format_actor(group)
      assert data["memberCount"] == Categories.members_count(group)
      assert data["memberCount"] >= 2
    end

    # the pair of the test above, for a hidden group (`members:private` visibility, not federated yet): the URI is declared all the same, since it says nothing about who is in it. The collection itself is not served at all: a group kept off the fediverse is served by no route, so it answers as a group that doesn't exist would, not "200, empty", which still says it exists
    test "a hidden group declares the collection but doesn't serve it" do
      creator = Bonfire.Me.Fake.fake_user!()
      member = Bonfire.Me.Fake.fake_user!()
      group = hidden_group(creator)

      # an invite-only group refuses `join_group/3`, so straight into the circle, as accepting an invite does
      {:ok, circle} = Categories.members_circle(group)
      Bonfire.Boundaries.Circles.add_to_circles(member, [circle])
      assert Categories.member?(member, group), "nobody joined, so this test proves nothing"

      assert %{data: data} = Categories.format_actor(group)
      assert data["members"] == ActivityPub.Utils.collection_ap_id("members", id(group))

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/collections/members/#{id(group)}")

      assert conn.status == 404, "Got #{conn.status}: #{conn.resp_body}"
      refute conn.resp_body =~ id(member), "the wire must not say more than the web does"
    end
  end
end
