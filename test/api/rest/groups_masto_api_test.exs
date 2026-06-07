defmodule Bonfire.Classify.API.MastoREST.GroupsTest do
  @moduledoc """
  REST API tests for groups endpoints (TDD — Phase 4 controller not yet implemented).

  Endpoints covered:
  - GET /api/v1-bonfire/groups
  - GET /api/v1-bonfire/groups/:id
  - POST /api/v1-bonfire/groups (create)
  - PATCH /api/v1-bonfire/groups/:id (update)
  - POST /api/v1-bonfire/groups/:id/join
  - POST /api/v1-bonfire/groups/:id/leave
  - GET /api/v1-bonfire/groups/:id/members
  - POST /api/v1-bonfire/groups/:id/members (add_member / accept request)
  - DELETE /api/v1-bonfire/groups/:id/members/:account_id (remove_member)
  - POST /api/v1/statuses with context_id (group and topic posting)
  """

  use Bonfire.Classify.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  import Bonfire.Me.Fake
  import Bonfire.Classify.Simulate

  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  @moduletag :rest_api

  defp masto_api_conn(user, account) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:current_account_id, account.id)
    |> Plug.Conn.put_session(:current_user_id, user.id)
  end

  setup do
    Process.put(:federating, false)
    account = fake_account!()
    me = fake_user!(account)
    group = fake_group!(me, %{membership: "open"})
    conn = masto_api_conn(me, account)
    {:ok, conn: conn, me: me, account: account, group: group}
  end

  describe "GET /api/v1-bonfire/groups" do
    test "returns list of Account objects with group extension", %{conn: conn, group: group} do
      response = conn |> get("/api/v1-bonfire/groups") |> json_response(200)
      assert is_list(response)
      item = Enum.find(response, &(&1["id"] == group.id))
      assert item, "group not found in response"
      assert item["display_name"]
      assert item["group"]["type"] in ["group", "topic", "label"]
      assert item["group"]["join_mode"] in ["free", "request", "invite"]
      assert is_boolean(item["group"]["is_disabled"])
      assert Map.has_key?(item["group"], "parent_group_id")
    end

    test "public groups visible without auth", %{group: _group} do
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/api/v1-bonfire/groups")
      |> json_response(200)
    end

    test "supports type filter returns only matching type", %{conn: conn, me: me} do
      _topic = fake_group!(me, %{type: :topic})
      response = conn |> get("/api/v1-bonfire/groups?type=topic") |> json_response(200)
      assert Enum.all?(response, &(get_in(&1, ["group", "type"]) == "topic"))
    end

    test "join_mode is free for local:members group", %{conn: conn, me: me} do
      g = fake_group!(me, %{membership: "local:members"})
      response = conn |> get("/api/v1-bonfire/groups") |> json_response(200)
      item = Enum.find(response, &(&1["id"] == g.id))
      assert item["group"]["join_mode"] == "free"
    end

    test "join_mode is request for on_request group", %{conn: conn, me: me} do
      g = fake_group!(me, %{membership: "on_request"})
      response = conn |> get("/api/v1-bonfire/groups") |> json_response(200)
      item = Enum.find(response, &(&1["id"] == g.id))
      assert item["group"]["join_mode"] == "request"
    end

    test "join_mode is invite for invite_only group", %{conn: conn, me: me} do
      g = fake_group!(me, %{membership: "invite_only"})
      response = conn |> get("/api/v1-bonfire/groups") |> json_response(200)
      item = Enum.find(response, &(&1["id"] == g.id))
      assert item["group"]["join_mode"] == "invite"
    end

    test "members_count is an integer", %{conn: conn, group: group} do
      response = conn |> get("/api/v1-bonfire/groups") |> json_response(200)
      item = Enum.find(response, &(&1["id"] == group.id))
      assert is_integer(item["group"]["members_count"])
    end

    test "boundaries array present with key and slug entries", %{conn: conn, group: group} do
      response = conn |> get("/api/v1-bonfire/groups") |> json_response(200)
      item = Enum.find(response, &(&1["id"] == group.id))
      assert is_list(item["group"]["boundaries"])
      assert Enum.any?(item["group"]["boundaries"], &Map.has_key?(&1, "key"))
    end
  end

  describe "GET /api/v1-bonfire/groups/:id" do
    test "returns single Account with group extension", %{conn: conn, group: group} do
      response = conn |> get("/api/v1-bonfire/groups/#{group.id}") |> json_response(200)
      assert response["id"] == group.id
      assert response["group"]["type"] == "group"
    end

    test "404 for nonexistent id", %{conn: conn} do
      conn |> get("/api/v1-bonfire/groups/nonexistent") |> json_response(404)
    end

    test "boundaries present on single group response", %{conn: conn, group: group} do
      response = conn |> get("/api/v1-bonfire/groups/#{group.id}") |> json_response(200)
      assert is_list(response["group"]["boundaries"])
      keys = Enum.map(response["group"]["boundaries"], & &1["key"])
      assert "membership" in keys
    end
  end

  describe "POST /api/v1-bonfire/groups (create)" do
    test "creates a group with name and returns Account with group extension", %{conn: conn} do
      response =
        conn
        |> post("/api/v1-bonfire/groups", %{"name" => "New Group"})
        |> json_response(200)

      assert is_binary(response["id"])
      assert response["display_name"] == "New Group"
      assert response["group"]["type"] == "group"
    end

    test "with boundary preset applies preset dimensions", %{conn: conn} do
      response =
        conn
        |> post("/api/v1-bonfire/groups", %{
          "name" => "Private Club",
          "boundary" => %{"preset" => "private_club"}
        })
        |> json_response(200)

      assert response["group"]["join_mode"] == "request"
    end

    test "requires auth to create", %{} do
      build_conn()
      |> put_req_header("accept", "application/json")
      |> post("/api/v1-bonfire/groups", %{"name" => "Unauthorized"})
      |> json_response(401)
    end
  end

  describe "PATCH /api/v1-bonfire/groups/:id (update)" do
    test "admin can update group name", %{conn: conn, group: group} do
      response =
        conn
        |> patch("/api/v1-bonfire/groups/#{group.id}", %{"name" => "Updated Name"})
        |> json_response(200)

      assert response["display_name"] == "Updated Name"
    end

    test "admin can update boundary preset and join_mode changes", %{conn: conn, group: group} do
      response =
        conn
        |> patch("/api/v1-bonfire/groups/#{group.id}", %{
          "boundary" => %{"preset" => "private_club"}
        })
        |> json_response(200)

      assert response["group"]["join_mode"] == "request"
    end

    test "non-admin cannot update group", %{group: group} do
      other_account = fake_account!()
      other = fake_user!(other_account)
      other_conn = masto_api_conn(other, other_account)

      other_conn
      |> patch("/api/v1-bonfire/groups/#{group.id}", %{"name" => "Hijacked"})
      |> json_response(403)
    end
  end

  describe "POST /api/v1-bonfire/groups/:id/join" do
    test "free group: returns extended Relationship with group.member true", %{group: group} do
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)
      joiner_conn = masto_api_conn(joiner, joiner_account)

      response =
        joiner_conn |> post("/api/v1-bonfire/groups/#{group.id}/join") |> json_response(200)

      assert response["id"] == group.id
      assert response["following"] == true
      assert response["requested"] == false
      assert response["group"]["member"] == true
      assert response["group"]["role"] == "member"
    end

    test "request-mode group: following false, requested true, member false", %{me: me} do
      request_group = fake_group!(me, %{membership: "on_request"})
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)
      joiner_conn = masto_api_conn(joiner, joiner_account)

      response =
        joiner_conn
        |> post("/api/v1-bonfire/groups/#{request_group.id}/join")
        |> json_response(200)

      assert response["following"] == false
      assert response["requested"] == true
      assert response["group"]["member"] == false
    end

    test "invite-only group: joining returns error", %{me: me} do
      invite_group = fake_group!(me, %{membership: "invite_only"})
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)
      joiner_conn = masto_api_conn(joiner, joiner_account)

      joiner_conn
      |> post("/api/v1-bonfire/groups/#{invite_group.id}/join")
      |> json_response(403)
    end

    test "joining an already-joined group is idempotent", %{group: group} do
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)
      joiner_conn = masto_api_conn(joiner, joiner_account)

      joiner_conn |> post("/api/v1-bonfire/groups/#{group.id}/join") |> json_response(200)

      response =
        joiner_conn |> post("/api/v1-bonfire/groups/#{group.id}/join") |> json_response(200)

      assert response["group"]["member"] == true
    end

    test "requires auth", %{group: group} do
      build_conn()
      |> put_req_header("accept", "application/json")
      |> post("/api/v1-bonfire/groups/#{group.id}/join")
      |> json_response(401)
    end
  end

  describe "POST /api/v1-bonfire/groups/:id/leave" do
    test "returns Relationship with following false and group.member false", %{
      conn: conn,
      me: me,
      group: group
    } do
      Bonfire.Classify.Categories.join_group(me, group)

      response = conn |> post("/api/v1-bonfire/groups/#{group.id}/leave") |> json_response(200)
      assert response["following"] == false
      assert response["group"]["member"] == false
      assert response["group"]["role"] == nil
    end

    test "requires auth", %{group: group} do
      build_conn()
      |> put_req_header("accept", "application/json")
      |> post("/api/v1-bonfire/groups/#{group.id}/leave")
      |> json_response(401)
    end
  end

  describe "GET /api/v1-bonfire/groups/:id/members" do
    test "returns list of {account, relationship} pairs", %{conn: conn, group: group} do
      member_account = fake_account!()
      member = fake_user!(member_account)
      Bonfire.Classify.Categories.join_group(member, group)

      response =
        conn |> get("/api/v1-bonfire/groups/#{group.id}/members") |> json_response(200)

      assert is_list(response)
      item = Enum.find(response, &(get_in(&1, ["account", "id"]) == member.id))
      assert item, "member not found in response"
      assert item["account"]["id"] == member.id
      assert item["relationship"]["id"] == member.id
      assert item["relationship"]["group"]["member"] == true
    end

    test "admin (creator) appears in members list", %{conn: conn, me: me, group: group} do
      response =
        conn |> get("/api/v1-bonfire/groups/#{group.id}/members") |> json_response(200)

      assert is_list(response)
      item = Enum.find(response, &(get_in(&1, ["account", "id"]) == me.id))
      assert item, "creator not found in members list"
      assert item["relationship"]["group"]["role"] == "admin"
      # TODO: test moderator roles?
    end

    test "role filter returns only matching members", %{conn: conn, group: group} do
      member_account = fake_account!()
      member = fake_user!(member_account)
      Bonfire.Classify.Categories.join_group(member, group)

      response =
        conn
        |> get("/api/v1-bonfire/groups/#{group.id}/members?role=member")
        |> json_response(200)

      assert is_list(response)
      roles = Enum.map(response, &get_in(&1, ["relationship", "group", "role"]))
      assert Enum.all?(roles, &(&1 == "member"))
    end

    test "requires auth to list members", %{group: group} do
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/api/v1-bonfire/groups/#{group.id}/members")
      |> json_response(401)
    end
  end

  describe "POST /api/v1-bonfire/groups/:id/members (add_member / accept request)" do
    test "admin can add a user by account_id", %{conn: conn, group: group} do
      new_member_account = fake_account!()
      new_member = fake_user!(new_member_account)

      response =
        conn
        |> post("/api/v1-bonfire/groups/#{group.id}/members", %{"account_id" => new_member.id})
        |> json_response(200)

      assert response["group"]["member"] == true
    end

    test "non-admin cannot add members", %{group: group} do
      other_account = fake_account!()
      other = fake_user!(other_account)
      other_conn = masto_api_conn(other, other_account)
      new_account = fake_account!()
      new_user = fake_user!(new_account)

      other_conn
      |> post("/api/v1-bonfire/groups/#{group.id}/members", %{"account_id" => new_user.id})
      |> json_response(403)
    end

    test "admin can accept a pending join request", %{conn: conn, me: me} do
      request_group = fake_group!(me, %{membership: "on_request"})
      requester_account = fake_account!()
      requester = fake_user!(requester_account)

      {:ok, _} = Bonfire.Classify.Categories.join_group(requester, request_group)
      refute Bonfire.Classify.Categories.member?(requester, request_group)

      [request] =
        Bonfire.Social.Requests.all_by_object(request_group, Bonfire.Data.Social.Follow,
          skip_boundary_check: true
        )

      response =
        conn
        |> post("/api/v1-bonfire/groups/#{request_group.id}/members", %{
          "request_id" => request.id
        })
        |> json_response(200)

      assert response["group"]["member"] == true
    end
  end

  describe "DELETE /api/v1-bonfire/groups/:id/members/:account_id (remove_member)" do
    test "admin can remove a member", %{conn: conn, group: group} do
      member_account = fake_account!()
      member = fake_user!(member_account)
      Bonfire.Classify.Categories.join_group(member, group)

      conn
      |> delete("/api/v1-bonfire/groups/#{group.id}/members/#{member.id}")
      |> json_response(200)

      refute Bonfire.Classify.Categories.member?(member, group)
    end

    test "non-admin cannot remove members", %{group: group} do
      member_account = fake_account!()
      member = fake_user!(member_account)
      Bonfire.Classify.Categories.join_group(member, group)

      other_account = fake_account!()
      other = fake_user!(other_account)
      other_conn = masto_api_conn(other, other_account)

      other_conn
      |> delete("/api/v1-bonfire/groups/#{group.id}/members/#{member.id}")
      |> json_response(403)
    end
  end

  describe "POST /api/v1/statuses in a group (posting with context_id)" do
    test "posting with context_id tags the post to the group", %{conn: conn, group: group} do
      response =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "Hello from this group!",
          "context_id" => group.id
        })
        |> json_response(200)

      assert is_binary(response["id"])
      assert response["content"] =~ "Hello from this group!"
      assert response["context_id"] == group.id
    end

    test "posting in a group with visibility override", %{conn: conn, group: group} do
      response =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "Members only post",
          "context_id" => group.id,
          "visibility" => "private"
        })
        |> json_response(200)

      assert is_binary(response["id"])
    end

    test "post in members:private group is not in local feed for 3rd party", %{conn: conn, me: me} do
      private_group = fake_group!(me, %{visibility: "members:private"})

      response =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "Secret post",
          "context_id" => private_group.id
        })
        |> json_response(200)

      post_id = response["id"]
      assert is_binary(post_id)

      third_account = fake_account!()
      third = fake_user!(third_account)
      {:ok, post} = Bonfire.Common.Needles.get(post_id, skip_boundary_check: true)
      refute Bonfire.Social.FeedLoader.feed_contains?(:local, post, current_user: third)
    end

    test "mentioning a group via @handle appears in the group's outbox feed", %{
      conn: conn,
      group: group
    } do
      response =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "@#{group.character.username} hello group"
        })
        |> json_response(200)

      post_id = response["id"]
      assert is_binary(post_id)

      {:ok, post} = Bonfire.Common.Needles.get(post_id, skip_boundary_check: true)

      %{edges: feed} =
        Bonfire.Social.FeedActivities.feed(:user_activities, by: group, current_user: group)

      assert Enum.any?(feed, &(&1.activity.object_id == post_id))
    end
  end

  describe "Topics" do
    test "create a topic via POST /api/v1-bonfire/groups returns type topic", %{conn: conn} do
      response =
        conn
        |> post("/api/v1-bonfire/groups", %{"name" => "My Topic", "type" => "topic"})
        |> json_response(200)

      assert is_binary(response["id"])
      assert response["group"]["type"] == "topic"
    end

    test "posting in a topic via context_id appears in topic's feed", %{conn: conn, me: me} do
      topic = fake_category!(me, nil, %{type: :topic})

      response =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "On-topic post",
          "context_id" => topic.id
        })
        |> json_response(200)

      post_id = response["id"]
      assert is_binary(post_id)

      {:ok, post} = Bonfire.Common.Needles.get(post_id, skip_boundary_check: true)

      %{edges: feed} =
        Bonfire.Social.FeedActivities.feed(:user_activities, by: topic, current_user: me)

      assert Enum.any?(feed, &(&1.activity.object_id == post_id))
    end

    test "topic in a local group: post not visible to unauthenticated guests", %{
      conn: conn,
      me: me
    } do
      group = fake_group!(me, %{default_content_visibility: "local"})
      topic = fake_category!(me, group)

      response =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "Local only content",
          "context_id" => topic.id
        })
        |> json_response(200)

      {:ok, post} =
        Bonfire.Common.Needles.get(response["id"], skip_boundary_check: true)

      refute Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post, by: topic)
    end

    test "posting in topic_a does not appear in sibling topic_b's feed", %{conn: conn, me: me} do
      group = fake_group!(me)
      topic_a = fake_category!(me, group, %{name: "Alpha"})
      topic_b = fake_category!(me, group, %{name: "Beta"})

      response =
        conn
        |> post("/api/v1/statuses", %{
          "status" => "Alpha post",
          "context_id" => topic_a.id
        })
        |> json_response(200)

      {:ok, post} =
        Bonfire.Common.Needles.get(response["id"], skip_boundary_check: true)

      refute Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: topic_b,
               current_user: me
             )
    end
  end
end
