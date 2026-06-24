if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupFeedDedupTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Me.Fake
    alias Bonfire.Social.FeedLoader
    alias Bonfire.Social.Graph.Follows

    setup do
      # TEMP: until we work on group federation
      Process.put(:federating, false)
      # ensure boundary preloads run synchronously in feed prep
      Process.put(:feed_live_update_many_preload_mode, :inline)
      :ok
    end

    defp assert_once_in_feed(feed_name, follower, author, group) do
      post = fake_post_in_group!(author, group)

      opts =
        case feed_name do
          :my -> [current_user: follower]
          :local -> [current_user: follower]
          :explore -> [current_user: follower]
        end

      %{edges: edges} = FeedLoader.feed(feed_name, opts)

      post_edges =
        Enum.filter(edges, fn edge ->
          e(edge, :activity, :object_id, nil) == post.id
        end)

      assert length(post_edges) == 1,
             "post should appear exactly once in #{feed_name} feed, got #{length(post_edges)} times " <>
               "(verbs: #{Enum.map_join(post_edges, ", ", &e(&1, :activity, :verb_id, "?"))})"
    end

    defp object_occurrences(edges, object_id) do
      Enum.filter(edges, fn edge ->
        e(edge, :activity, :object_id, nil) == object_id or
          e(edge, :activity, :object, :id, nil) == object_id
      end)
    end

    describe "group post dedup — following feed" do
      test "default group boundaries" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()
        group = fake_group!(author)
        {:ok, _} = Follows.follow(follower, author)
        {:ok, _} = Follows.follow(follower, group)
        assert_once_in_feed(:my, follower, author, group)
      end

      test "membership: local:members" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()
        group = fake_group!(author, %{membership: "local:members"})
        {:ok, _} = Follows.follow(follower, author)
        {:ok, _} = Follows.follow(follower, group)
        assert_once_in_feed(:my, follower, author, group)
      end

      test "participation: anyone" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()
        group = fake_group!(author, %{participation: "anyone"})
        {:ok, _} = Follows.follow(follower, author)
        {:ok, _} = Follows.follow(follower, group)
        assert_once_in_feed(:my, follower, author, group)
      end

      test "visibility: global" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()
        group = fake_group!(author, %{visibility: "global"})
        {:ok, _} = Follows.follow(follower, author)
        {:ok, _} = Follows.follow(follower, group)
        assert_once_in_feed(:my, follower, author, group)
      end

      test "membership: local:members + participation: anyone + visibility: global (full combo)" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()

        group =
          fake_group!(author, %{
            membership: "local:members",
            participation: "anyone",
            visibility: "global"
          })

        {:ok, _} = Follows.follow(follower, author)
        {:ok, _} = Follows.follow(follower, group)
        assert_once_in_feed(:my, follower, author, group)
      end

      test "full combo — following group only (not author)" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()

        group =
          fake_group!(author, %{
            membership: "local:members",
            participation: "anyone",
            visibility: "global"
          })

        {:ok, _} = Follows.follow(follower, group)
        assert_once_in_feed(:my, follower, author, group)
      end

      test "full combo — following author only (not group)" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()

        group =
          fake_group!(author, %{
            membership: "local:members",
            participation: "anyone",
            visibility: "global"
          })

        {:ok, _} = Follows.follow(follower, author)
        assert_once_in_feed(:my, follower, author, group)
      end
    end

    describe "group post dedup — local feed" do
      test "full combo — local feed shows post only once" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()

        group =
          fake_group!(author, %{
            membership: "local:members",
            participation: "anyone",
            visibility: "global"
          })

        {:ok, _} = Follows.follow(follower, author)
        {:ok, _} = Follows.follow(follower, group)
        assert_once_in_feed(:local, follower, author, group)
      end
    end

    describe "group post dedup — explore feed" do
      test "full combo — explore feed shows post only once" do
        follower = Fake.fake_user!()
        author = Fake.fake_user!()

        group =
          fake_group!(author, %{
            membership: "local:members",
            participation: "anyone",
            visibility: "global"
          })

        {:ok, _} = Follows.follow(follower, author)
        {:ok, _} = Follows.follow(follower, group)
        assert_once_in_feed(:explore, follower, author, group)
      end
    end

    test "a top-level post created in a group appears only once in the author's feed" do
      creator = Fake.fake_user!()
      group = fake_group!(creator, %{visibility: "global"})

      post = fake_post_in_group!(creator, group, "<p>Top-level group post</p>")

      %{edges: edges} =
        FeedLoader.feed(:my, %{show_objects_only_once: true}, current_user: creator)

      assert length(object_occurrences(edges, post.id)) == 1
    end

    test "a reply created in a group appears only once in the author's feed" do
      creator = Fake.fake_user!()
      group = fake_group!(creator, %{visibility: "global"})

      # root post in the group
      root = fake_post_in_group!(creator, group, "<p>Root post</p>")

      # reply published in the group context (triggers the group auto-boost of the reply)
      {:ok, reply} =
        Bonfire.Posts.publish(
          current_user: creator,
          post_attrs: %{
            reply_to_id: root.id,
            post_content: %{html_body: "<p>A reply in the group</p>"}
          },
          context_id: group.id,
          to_circles: Bonfire.Classify.Boundaries.post_circles_for_group(group),
          to_boundaries:
            List.wrap(Bonfire.Classify.Boundaries.read_default_content_visibility(group))
        )

      %{edges: edges} =
        FeedLoader.feed(:my, %{show_objects_only_once: true}, current_user: creator)

      assert length(object_occurrences(edges, reply.id)) == 1
    end
  end
end
