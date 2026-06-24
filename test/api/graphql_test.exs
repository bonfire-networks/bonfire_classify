if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Classify.GraphQL.SchemaTest do
    use Bonfire.Classify.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema
    alias Bonfire.Social.Graph.Follows

    import Bonfire.Classify.Simulate
    import Bonfire.Me.Fake

    @moduletag :graphql

    setup do
      Process.put(:federating, false)
      account = fake_account!()
      me = fake_user!(account)
      group = fake_group!(me, %{membership: "open"})
      {:ok, me: me, account: account, group: group}
    end

    test "join_group returns member: true and correct fields", %{me: me, group: group} do
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!) { join_group(group_id: $id) { member following requested role } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: joiner})
        )

      rel = get_in(result, [:data, "join_group"])
      assert rel["member"] == true
      assert rel["following"] == true
      assert rel["requested"] == false
      refute result[:errors]
    end

    test "join_group on request-mode group returns requested: true, member: false", %{me: me} do
      request_group = fake_group!(me, %{membership: "on_request"})
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!) { join_group(group_id: $id) { member requested } }|,
          Schema,
          variables: %{"id" => request_group.id},
          context: Schema.context(%{current_user: joiner})
        )

      rel = get_in(result, [:data, "join_group"])
      assert rel["member"] == false
      assert rel["requested"] == true
      refute result[:errors]
    end

    test "leave_group returns member: false and following: false", %{me: me, group: group} do
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)
      Bonfire.Classify.Categories.join_group(joiner, group.id)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!) { leave_group(group_id: $id) { member following } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: joiner})
        )

      rel = get_in(result, [:data, "leave_group"])
      assert rel["member"] == false
      assert rel["following"] == false
      refute result[:errors]
    end

    test "leave_group cancels a pending join request", %{me: me} do
      request_group = fake_group!(me, %{membership: "on_request"})
      requester_account = fake_account!()
      requester = fake_user!(requester_account)

      {:ok, _} = Bonfire.Classify.Categories.join_group(requester, request_group)
      assert Bonfire.Social.Graph.Follows.requested?(requester, request_group)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!) { leave_group(group_id: $id) { member following requested } }|,
          Schema,
          variables: %{"id" => request_group.id},
          context: Schema.context(%{current_user: requester})
        )

      rel = get_in(result, [:data, "leave_group"])
      assert rel["member"] == false
      assert rel["following"] == false
      assert rel["requested"] == false
      refute Bonfire.Social.Graph.Follows.requested?(requester, request_group)
      refute result[:errors]
    end

    test "add_member allows admin to add a user", %{me: me, group: group} do
      new_member_account = fake_account!()
      new_member = fake_user!(new_member_account)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($gid: ID!, $uid: ID!) { add_member(group_id: $gid, account_id: $uid) { member role } }|,
          Schema,
          variables: %{"gid" => group.id, "uid" => new_member.id},
          context: Schema.context(%{current_user: me})
        )

      rel = get_in(result, [:data, "add_member"])
      assert rel["member"] == true
      refute result[:errors]
    end

    test "remove_member returns true", %{me: me, group: group} do
      member_account = fake_account!()
      member = fake_user!(member_account)
      Bonfire.Classify.Categories.join_group(member, group.id)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($gid: ID!, $uid: ID!) { remove_member(group_id: $gid, account_id: $uid) }|,
          Schema,
          variables: %{"gid" => group.id, "uid" => member.id},
          context: Schema.context(%{current_user: me})
        )

      assert get_in(result, [:data, "remove_member"]) == true
      refute result[:errors]
    end

    test "category.members entries include account and relationship", %{me: me, group: group} do
      member_account = fake_account!()
      member = fake_user!(member_account)
      Bonfire.Classify.Categories.join_group(member, group.id)

      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { members { entries { account { id } relationship { following } } } } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      entries = get_in(result, [:data, "category", "members", "entries"])
      assert is_list(entries)
      assert Enum.any?(entries, &(get_in(&1, ["account", "id"]) == member.id))
      refute result[:errors]
    end

    test "category.members relationship.member is true for joined members", %{
      me: me,
      group: group
    } do
      member_account = fake_account!()
      member = fake_user!(member_account)
      Bonfire.Classify.Categories.join_group(member, group.id)

      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { members { entries { account { id } relationship { member role } } } } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      entries = get_in(result, [:data, "category", "members", "entries"])
      assert is_list(entries)
      entry = Enum.find(entries, &(get_in(&1, ["account", "id"]) == member.id))
      assert entry, "member not found in entries"
      assert get_in(entry, ["relationship", "member"]) == true
      refute result[:errors]
    end

    test "category.members maps topic follower edges to accounts", %{me: me} do
      topic = fake_category!(me, nil, %{type: :topic})
      follower_account = fake_account!()
      follower = fake_user!(follower_account)
      assert {:ok, _follow} = Follows.follow(follower, topic, skip_boundary_check: true)

      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { members { entries { account { id } relationship { member role } } } } }|,
          Schema,
          variables: %{"id" => topic.id},
          context: Schema.context(%{current_user: me})
        )

      entries = get_in(result, [:data, "category", "members", "entries"])
      assert is_list(entries)
      entry = Enum.find(entries, &(get_in(&1, ["account", "id"]) == follower.id))
      assert entry, "topic follower not found in entries"
      assert get_in(entry, ["relationship", "member"]) == true
      assert get_in(entry, ["relationship", "role"]) == "member"
      refute result[:errors]
    end

    test "mutations require auth" do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!) { join_group(group_id: $id) { member } }|,
          Schema,
          variables: %{"id" => "some-id"},
          context: Schema.context(%{})
        )

      assert result[:errors]
    end

    test "category.type is returned", %{group: group, me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { type } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      assert get_in(result, [:data, "category", "type"]) in ["group", "topic", "label"]
      refute result[:errors]
    end

    test "category.members_count is an integer", %{group: group, me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { members_count } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      assert is_integer(get_in(result, [:data, "category", "members_count"]))
      refute result[:errors]
    end

    test "category.is_disabled is false for a live group", %{group: group, me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { is_disabled } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      assert get_in(result, [:data, "category", "is_disabled"]) == false
      refute result[:errors]
    end

    test "category.boundaries includes membership key for a group", %{group: group, me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { boundaries { key slug } } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      dims = get_in(result, [:data, "category", "boundaries"])
      assert is_list(dims)
      keys = Enum.map(dims, & &1["key"])
      assert "membership" in keys
      refute result[:errors]
    end

    test "user.groups returns the user's joined groups", %{me: me, group: group} do
      {:ok, result} =
        Absinthe.run(
          ~S|{ me { user { groups { edges { id } } } } }|,
          Schema,
          context: Schema.context(%{current_user: me})
        )

      ids =
        get_in(result, [:data, "me", "user", "groups", "edges"]) |> Enum.map(& &1["id"])

      assert group.id in ids
      refute result[:errors]
    end

    test "create_category creates a group and returns its id and type", %{me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation { create_category(category: {name: "Test Group", type: "group"}) { id type name } }|,
          Schema,
          context: Schema.context(%{current_user: me})
        )

      cat = get_in(result, [:data, "create_category"])
      assert is_binary(cat["id"])
      assert cat["name"] == "Test Group"
      refute result[:errors]
    end

    test "category query returns a group by id", %{me: me, group: group} do
      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { id name type } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      cat = get_in(result, [:data, "category"])
      assert cat["id"] == group.id
      assert cat["type"] == "group"
      refute result[:errors]
    end

    test "categories query lists categories including the group", %{me: me, group: group} do
      {:ok, result} =
        Absinthe.run(
          ~S|{ categories { edges { id type } } }|,
          Schema,
          context: Schema.context(%{current_user: me})
        )

      edges = get_in(result, [:data, "categories", "edges"])
      assert is_list(edges)
      ids = Enum.map(edges, & &1["id"])
      assert group.id in ids
      refute result[:errors]
    end

    test "create_post with context_id tags post to the group", %{me: me, group: group} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation($ctx: ID!) {
            create_post(post_content: {html_body: "<p>Posted in group</p>"}, context_id: $ctx) {
              id
              context { ... on Category { id } ... on Other { id } }
            }
          }|,
          Schema,
          variables: %{"ctx" => group.id},
          context: Schema.context(%{current_user: me})
        )

      post = get_in(result, [:data, "create_post"])
      assert is_binary(post["id"])
      assert get_in(post, ["context", "id"]) == group.id
      refute result[:errors]
    end

    test "create_category with preset applies preset dimensions", %{me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation { create_category(category: {name: "Private Club", type: "group", boundary: {preset: "private_club"}}) { id boundaries { key slug } } }|,
          Schema,
          context: Schema.context(%{current_user: me})
        )

      cat = get_in(result, [:data, "create_category"])
      assert is_binary(cat["id"])
      dims = Map.new(cat["boundaries"], &{&1["key"], &1["slug"]})
      assert dims["membership"] == "on_request"
      refute result[:errors]
    end

    test "create_category with preset + overrides applies overrides on top", %{me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation { create_category(category: {name: "Club", type: "group", boundary: {preset: "private_club", overrides: [{key: "discoverable", value: true}]}}) { id boundaries { key slug } } }|,
          Schema,
          context: Schema.context(%{current_user: me})
        )

      cat = get_in(result, [:data, "create_category"])
      assert is_binary(cat["id"])
      dims = Map.new(cat["boundaries"], &{&1["key"], &1["slug"]})
      assert String.contains?(dims["visibility"] || "", "discover")
      refute result[:errors]
    end

    test "create_category with explicit dimensions sets membership dimension", %{me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation { create_category(category: {name: "Community", type: "group", boundary: {dimensions: [{key: "membership", value: "open"}]}}) { id boundaries { key slug } } }|,
          Schema,
          context: Schema.context(%{current_user: me})
        )

      cat = get_in(result, [:data, "create_category"])
      assert is_binary(cat["id"])
      dims = Map.new(cat["boundaries"], &{&1["key"], &1["slug"]})
      assert dims["membership"] == "open"
      refute result[:errors]
    end

    test "create_category with preset + overrides + dimensions applies all three layers",
         %{me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation {
            create_category(category: {
              name: "Full Config",
              type: "group",
              boundary: {
                preset: "public_local_community",
                overrides: [{key: "approval_required", value: true}],
                dimensions: [{key: "participation", value: "local:contributors"}]
              }
            }) { id boundaries { key slug } }
          }|,
          Schema,
          context: Schema.context(%{current_user: me})
        )

      cat = get_in(result, [:data, "create_category"])
      assert is_binary(cat["id"])
      dims = Map.new(cat["boundaries"], &{&1["key"], &1["slug"]})
      # approval_required: true override sets membership to on_request (overrides preset default)
      assert dims["membership"] == "on_request"
      assert dims["participation"] == "local:contributors"
      refute result[:errors]
    end

    test "update_category changes the group's preset and dimensions", %{me: me, group: group} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!) {
            update_category(category_id: $id, category: {boundary: {preset: "private_club"}}) {
              id boundaries { key slug }
            }
          }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      cat = get_in(result, [:data, "update_category"])
      assert cat["id"] == group.id
      dims = Map.new(cat["boundaries"], &{&1["key"], &1["slug"]})
      assert dims["membership"] == "on_request"
      refute result[:errors]
    end

    test "update_category changes the group name", %{me: me, group: group} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!, $name: String) {
            update_category(category_id: $id, category: {name: $name}) { name }
          }|,
          Schema,
          variables: %{"id" => group.id, "name" => "Updated Name"},
          context: Schema.context(%{current_user: me})
        )

      assert get_in(result, [:data, "update_category", "name"]) == "Updated Name"
      refute result[:errors]
    end

    test "category.members filters by role", %{me: me, group: group} do
      mod_account = fake_account!()
      mod = fake_user!(mod_account)
      regular_account = fake_account!()
      regular = fake_user!(regular_account)
      Bonfire.Classify.Categories.join_group(mod, group)
      Bonfire.Classify.Categories.join_group(regular, group)

      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) { category(category_id: $id) { members(role: "member") { entries { account { id } } } } }|,
          Schema,
          variables: %{"id" => group.id},
          context: Schema.context(%{current_user: me})
        )

      entries = get_in(result, [:data, "category", "members", "entries"])
      assert is_list(entries)
      ids = Enum.map(entries, &get_in(&1, ["account", "id"]))
      assert mod.id in ids
      assert regular.id in ids
      refute result[:errors]
    end

    test "join_group on invite-only group returns error", %{me: me} do
      invite_group = fake_group!(me, %{membership: "invite_only"})
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($id: ID!) { join_group(group_id: $id) { member } }|,
          Schema,
          variables: %{"id" => invite_group.id},
          context: Schema.context(%{current_user: joiner})
        )

      assert result[:errors]
    end

    test "join_group and leave_group return GraphQL errors for missing group ids", %{me: me} do
      missing_id = "01JABCDEF0000000000000000G"

      {:ok, join_result} =
        Absinthe.run(
          ~S|mutation($id: ID!) { join_group(group_id: $id) { member requested } }|,
          Schema,
          variables: %{"id" => missing_id},
          context: Schema.context(%{current_user: me})
        )

      assert join_result[:errors]
      assert get_in(join_result, [:data, "join_group"]) == nil

      {:ok, leave_result} =
        Absinthe.run(
          ~S|mutation($id: ID!) { leave_group(group_id: $id) { member requested } }|,
          Schema,
          variables: %{"id" => missing_id},
          context: Schema.context(%{current_user: me})
        )

      assert leave_result[:errors]
      assert get_in(leave_result, [:data, "leave_group"]) == nil
    end

    test "member_role: creator has admin role, joiner has member role", %{me: me} do
      new_group = fake_group!(me, %{membership: "open"})
      joiner_account = fake_account!()
      joiner = fake_user!(joiner_account)
      Bonfire.Classify.Categories.join_group(joiner, new_group)

      assert Bonfire.Classify.Categories.member_role(me, new_group) == "admin"
      assert Bonfire.Classify.Categories.member_role(joiner, new_group) == "member"

      assert Bonfire.Classify.Categories.member_role(fake_user!(fake_account!()), new_group) ==
               nil
    end

    test "request-to-join: accept_join_request makes user a member", %{me: me} do
      request_group = fake_group!(me, %{membership: "on_request"})
      requester_account = fake_account!()
      requester = fake_user!(requester_account)

      {:ok, _} = Bonfire.Classify.Categories.join_group(requester, request_group)
      refute Bonfire.Classify.Categories.member?(requester, request_group)

      [request] =
        Bonfire.Social.Requests.all_by_object(request_group, Bonfire.Data.Social.Follow,
          skip_boundary_check: true
        )

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($req: ID!) { accept_join_request(request_id: $req) { member } }|,
          Schema,
          variables: %{"req" => request.id},
          context: Schema.context(%{current_user: me})
        )

      rel = get_in(result, [:data, "accept_join_request"])
      assert rel["member"] == true
      refute result[:errors]
    end

    test "group_join_requests lists pending request ids for moderators", %{me: me} do
      request_group = fake_group!(me, %{membership: "on_request"})
      requester_account = fake_account!()
      requester = fake_user!(requester_account)

      {:ok, _} = Bonfire.Classify.Categories.join_group(requester, request_group)
      refute Bonfire.Classify.Categories.member?(requester, request_group)

      [request] =
        Bonfire.Social.Requests.all_by_object(request_group, Bonfire.Data.Social.Follow,
          skip_boundary_check: true
        )

      {:ok, result} =
        Absinthe.run(
          ~S|query($id: ID!) {
            group_join_requests(group_id: $id) {
              entries { request_id account { id } }
            }
          }|,
          Schema,
          variables: %{"id" => request_group.id},
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      entries = get_in(result, [:data, "group_join_requests", "entries"])
      request_id = request.id
      requester_id = requester.id
      assert [%{"request_id" => ^request_id, "account" => %{"id" => ^requester_id}}] = entries
    end

    test "post in members:private group is not readable by outsider", %{me: me} do
      private_group = fake_group!(me, %{visibility: "members:private"})

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($ctx: ID!) {
            create_post(post_content: {html_body: "<p>Secret</p>"}, context_id: $ctx) { id }
          }|,
          Schema,
          variables: %{"ctx" => private_group.id},
          context: Schema.context(%{current_user: me})
        )

      post_id = get_in(result, [:data, "create_post", "id"])
      assert is_binary(post_id)
      refute result[:errors]

      outsider_account = fake_account!()
      outsider = fake_user!(outsider_account)

      {:ok, post} = Bonfire.Common.Needles.get(post_id, skip_boundary_check: true)
      refute Bonfire.Boundaries.can?(outsider, [:read], post)
    end

    test "post in open group is readable by non-member", %{me: me, group: group} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation($ctx: ID!) {
            create_post(post_content: {html_body: "<p>Public</p>"}, context_id: $ctx) { id }
          }|,
          Schema,
          variables: %{"ctx" => group.id},
          context: Schema.context(%{current_user: me})
        )

      post_id = get_in(result, [:data, "create_post", "id"])
      assert is_binary(post_id)

      outsider_account = fake_account!()
      outsider = fake_user!(outsider_account)

      {:ok, post} = Bonfire.Common.Needles.get(post_id, skip_boundary_check: true)
      assert Bonfire.Boundaries.can?(outsider, [:read], post)
    end

    test "mentioning a group in a post makes it appear in the group's outbox feed", %{
      me: me,
      group: group
    } do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation($body: String!) {
            create_post(post_content: {html_body: $body}) { id }
          }|,
          Schema,
          variables: %{"body" => "<p>@#{group.character.username} hello group</p>"},
          context: Schema.context(%{current_user: me})
        )

      post_id = get_in(result, [:data, "create_post", "id"])
      assert is_binary(post_id)
      refute result[:errors]

      %{edges: feed} =
        Bonfire.Social.FeedActivities.feed(:user_activities, by: group, current_user: me)

      assert Enum.any?(feed, &(&1.activity.object_id == post_id))
    end

    test "post in non-public group does not appear in local instance feed for 3rd party", %{
      me: me
    } do
      private_group = fake_group!(me, %{visibility: "members:private"})
      post = fake_post_in_group!(me, private_group, "<p>Private post</p>")

      third_account = fake_account!()
      third = fake_user!(third_account)

      refute Bonfire.Social.FeedLoader.feed_contains?(:local, post, current_user: third)
    end

    test "create_category with type topic returns a topic", %{me: me} do
      {:ok, result} =
        Absinthe.run(
          ~S|mutation { create_category(category: {name: "My Topic", type: "topic"}) { id type } }|,
          Schema,
          context: Schema.context(%{current_user: me})
        )

      cat = get_in(result, [:data, "create_category"])
      assert is_binary(cat["id"])
      assert cat["type"] == "topic"
      refute result[:errors]
    end

    test "post with context_id on a topic appears in the topic's outbox feed", %{me: me} do
      topic = fake_category!(me, nil, %{type: :topic})

      {:ok, result} =
        Absinthe.run(
          ~S|mutation($ctx: ID!) {
            create_post(post_content: {html_body: "<p>On topic</p>"}, context_id: $ctx) { id }
          }|,
          Schema,
          variables: %{"ctx" => topic.id},
          context: Schema.context(%{current_user: me})
        )

      post_id = get_in(result, [:data, "create_post", "id"])
      assert is_binary(post_id)
      refute result[:errors]

      %{edges: feed} =
        Bonfire.Social.FeedActivities.feed(:user_activities, by: topic, current_user: me)

      assert Enum.any?(feed, &(&1.activity.object_id == post_id))
    end

    test "post in local group topic is not visible to guests", %{me: me} do
      group = fake_group!(me, %{default_content_visibility: "local"})
      topic = fake_category!(me, group)
      post = fake_post_in_topic!(me, topic, "<p>Local content</p>")

      refute Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post, by: topic)
    end
  end
end
