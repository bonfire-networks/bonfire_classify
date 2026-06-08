if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupFeedDedupTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Me.Fake
    alias Bonfire.Social.FeedLoader
    alias Bonfire.Social.Graph.Follows

    setup do
      Process.put(:federating, false)
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
  end
end
