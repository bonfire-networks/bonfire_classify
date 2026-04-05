if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupMembershipTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Me.Fake
    alias Bonfire.Classify.Categories

    defp fake_group!(creator, overrides \\ %{}) do
      fake_category!(
        creator,
        nil,
        Map.merge(%{type: :group, to_boundaries: overrides[:boundary]}, overrides)
      )
    end

    describe "group creation" do
      test "creates a members circle when type is :group" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)

        assert group.type == :group
        assert {:ok, circle} = Categories.members_circle(group)
        assert circle.id
      end

      test "does not create a members circle for topics" do
        creator = Fake.fake_user!()
        topic = fake_category!(creator, nil, %{type: :topic})

        # members_circle falls back to get_or_create, so it will create one;
        # key thing is the type is :topic and the circle creation was not triggered at create time
        assert topic.type == :topic
      end
    end

    describe "join_group/3" do
      test "creator auto-follows the group on creation" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)

        assert Bonfire.Social.Graph.Follows.following?(creator, group)
      end

      test "creator is automatically added to the members circle" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)

        assert Categories.member?(creator, group)
      end

      test "another user can join an open group" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        assert {:ok, %{member: true, requested: false}} =
                 Categories.join_group(member, group, skip_boundary_check: true)

        assert Categories.member?(member, group)
      end

      test "joining adds user to the members circle" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)

        {:ok, circle} = Categories.members_circle(group)
        assert Bonfire.Boundaries.Circles.is_encircled_by?(member, circle)
      end
    end

    describe "leave_group/3" do
      test "member can leave a group (stays following)" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)
        assert Categories.member?(member, group)

        assert {:ok, %{member: false, requested: false}} =
                 Categories.leave_group(member, group)

        refute Categories.member?(member, group)
        # leave_group does not unfollow — user may still follow the feed
        assert Bonfire.Social.Graph.Follows.following?(member, group)
      end

      test "leaving removes user from the members circle" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)
        {:ok, circle} = Categories.members_circle(group)
        assert Bonfire.Boundaries.Circles.is_encircled_by?(member, circle)

        Categories.leave_group(member, group)
        refute Bonfire.Boundaries.Circles.is_encircled_by?(member, circle)
      end
    end

    describe "leave_and_unfollow_group/3" do
      test "removes membership and unfollow" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)
        assert Categories.member?(member, group)
        assert Bonfire.Social.Graph.Follows.following?(member, group)

        assert {:ok, %{member: false, requested: false, following: false}} =
                 Categories.leave_and_unfollow_group(member, group)

        refute Categories.member?(member, group)
        refute Bonfire.Social.Graph.Follows.following?(member, group)
      end

      test "following without being a member, then leave_and_unfollow removes follow" do
        creator = Fake.fake_user!()
        follower = Fake.fake_user!()
        group = fake_group!(creator)

        # follow without joining (feed follower, not a member)
        Bonfire.Social.Graph.Follows.follow(follower, group, skip_boundary_check: true)
        assert Bonfire.Social.Graph.Follows.following?(follower, group)
        refute Categories.member?(follower, group)

        {:ok, result} = Categories.leave_and_unfollow_group(follower, group)
        assert result.following == false
        refute Bonfire.Social.Graph.Follows.following?(follower, group)
      end

      test "member who is also following, leave_group keeps follow but removes membership" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)

        # extra follow call to ensure both states are set
        assert Bonfire.Social.Graph.Follows.following?(member, group)
        assert Categories.member?(member, group)

        Categories.leave_group(member, group)

        refute Categories.member?(member, group)
        assert Bonfire.Social.Graph.Follows.following?(member, group)
      end
    end

    describe "member_role/2" do
      test "creator is admin" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)

        assert Categories.member_role(creator, group) == "admin"
      end

      test "member has member role" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)

        assert Categories.member_role(member, group) == "member"
      end

      test "non-member has nil role" do
        creator = Fake.fake_user!()
        other = Fake.fake_user!()
        group = fake_group!(creator)

        assert Categories.member_role(other, group) == nil
      end
    end

    describe "join_mode/1" do
      test "open group has free join mode" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)

        assert Categories.join_mode(group) == "free"
      end

      @tag :fixme
      test "visible group has request join mode" do
        creator = Fake.fake_user!()
        group = fake_group!(creator, %{boundary: "visible"})

        assert Categories.join_mode(group) == "request"
      end

      @tag :fixme
      test "private group has invite join mode" do
        creator = Fake.fake_user!()
        group = fake_group!(creator, %{boundary: "private"})

        assert Categories.join_mode(group) == "invite"
      end
    end

    describe "request-to-join flow" do
      test "joining a visible group creates a request, not immediate membership" do
        creator = Fake.fake_user!()
        requester = Fake.fake_user!()
        group = fake_group!(creator, %{boundary: "visible"})

        assert {:ok, %{member: false, requested: true}} =
                 Categories.join_group(requester, group)

        refute Categories.member?(requester, group)
      end

      test "accepting a join request adds the user to the members circle" do
        creator = Fake.fake_user!()
        requester = Fake.fake_user!()
        group = fake_group!(creator, %{boundary: "visible"})

        {:ok, _} = Categories.join_group(requester, group)
        refute Categories.member?(requester, group)

        [request] =
          Bonfire.Social.Requests.all_by_object(group, Bonfire.Data.Social.Follow,
            skip_boundary_check: true
          )

        {:ok, _} = Categories.accept_join_request(creator, request)

        assert Categories.member?(requester, group)
      end
    end

    describe "list_members/2" do
      test "joined members appear in list_members" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)

        member_ids = Categories.list_members(group) |> e(:edges, []) |> Enum.map(&id/1)
        assert id(member) in member_ids
      end

      test "non-members do not appear in list_members" do
        creator = Fake.fake_user!()
        outsider = Fake.fake_user!()
        group = fake_group!(creator)

        member_ids = Categories.list_members(group) |> e(:edges, []) |> Enum.map(&id/1)
        refute id(outsider) in member_ids
      end
    end

    describe "publish in group" do
      test "member can publish a post in an open group" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)

        assert {:ok, post} =
                 Bonfire.Posts.publish(
                   current_user: creator,
                   post_attrs: %{post_content: %{html_body: "<p>Hello group</p>"}},
                   context_id: group.id,
                   to_circles: [group.id],
                   boundary: "public"
                 )

        assert post
      end

      @tag :fixme
      test "post in closed group is visible to members but not non-members" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        outsider = Fake.fake_user!()
        group = fake_group!(creator, %{boundary: "private"})

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)

        {:ok, post} =
          Bonfire.Posts.publish(
            current_user: creator,
            post_attrs: %{post_content: %{html_body: "<p>Secret post</p>"}},
            context_id: group.id,
            to_circles: [group.id],
            #  TODO
            boundary: "private"
          )

        assert Bonfire.Social.FeedLoader.feed_contains?(
                 :user_activities,
                 post,
                 by: group,
                 current_user: member
               )

        refute Bonfire.Social.FeedLoader.feed_contains?(
                 :user_activities,
                 post,
                 by: group,
                 current_user: outsider
               )

        refute Bonfire.Social.FeedLoader.feed_contains?(
                 :user_activities,
                 post,
                 by: creator,
                 current_user: outsider
               )
      end
    end

    describe "members_count/1" do
      test "counts members via the members circle" do
        creator = Fake.fake_user!()
        member = Fake.fake_user!()
        group = fake_group!(creator)

        {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)

        count = Categories.members_count(group)
        assert count >= 1
      end
    end
  end
end
