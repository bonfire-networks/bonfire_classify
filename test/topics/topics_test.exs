if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.TopicTagMentionsTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Posts
    alias Bonfire.Social.FeedActivities
    alias Bonfire.Social.FeedLoader
    alias Bonfire.Classify.Categories

    alias Bonfire.Me.Fake

    test "post in a topic appears in the topic's feed" do
      me = Fake.fake_user!()
      topic = fake_category!(me)

      post = fake_post_in_topic!(me, topic, "<p>On topic content</p>")
      assert post

      assert Bonfire.Social.FeedLoader.feed_contains?(
               :user_activities,
               post,
               by: topic,
               current_user: me
             )
    end

    test "post in a topic inside a local group is not visible to guests" do
      me = Fake.fake_user!()
      group = fake_group!(me, %{default_content_visibility: "local"})
      topic = fake_category!(me, group)

      post = fake_post_in_topic!(me, topic, "<p>Local content</p>")

      refute Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post, by: topic)
    end

    test "can post with a topic mention" do
      me = Fake.fake_user!()
      topic = fake_category!(me)
      msg = "+#{topic.character.username} you have an epic text message"
      attrs = %{post_content: %{html_body: msg}}

      assert {:ok, post} =
               Posts.publish(
                 current_user: me,
                 post_attrs: attrs,
                 boundary: "mentions"
               )

      assert String.contains?(post.post_content.html_body, "epic text message")
      assert String.contains?(post.post_content.html_body, "+#{topic.character.username}")
    end

    test "mentioning a topic appears in its outbox feed" do
      me = Fake.fake_user!()
      topic = fake_category!(me)

      attrs = %{
        post_content: %{
          html_body: "+#{topic.character.username} this is very on topic"
        }
      }

      assert {:ok, mention} =
               Posts.publish(
                 current_user: me,
                 post_attrs: attrs,
                 boundary: "mentions"
               )

      assert %{edges: feed} =
               FeedActivities.feed(:user_activities, by: topic, current_user: me)

      assert %{} = fp = List.first(feed)
      assert fp.activity.object_id == mention.id
    end

    test "mentioning a topic does not appear in a 3rd party's instance feed" do
      me = Fake.fake_user!()
      topic = fake_category!(me)

      attrs = %{
        post_content: %{
          html_body: "+#{topic.character.username} this is very on topic"
        }
      }

      assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)

      third = Fake.fake_user!()
      refute Bonfire.Social.FeedLoader.feed_contains?(:local, mention, current_user: third)
    end

    test "mentioning a topic with local preset does not appear publicly (for guests)" do
      me = Fake.fake_user!()
      topic = fake_category!(me)

      attrs = %{
        post_content: %{
          html_body: "+#{topic.character.username} this is very on topic"
        }
      }

      assert {:ok, mention} =
               Posts.publish(
                 current_user: me,
                 post_attrs: attrs
               )

      refute Bonfire.Social.FeedLoader.feed_contains?(:local, mention)
    end

    test "mentioning a topic appears in my instance feed (if using local preset)" do
      me = Fake.fake_user!()
      topic = fake_category!(me)

      attrs = %{
        post_content: %{
          html_body: "+#{topic.character.username} this is very on topic"
        }
      }

      assert {:ok, mention} =
               Posts.publish(
                 current_user: me,
                 post_attrs: attrs,
                 boundary: "local"
               )

      assert %{edges: feed} = FeedActivities.feed(:local, current_user: me)
      assert %{} = fp = List.first(feed)
      assert fp.activity.object_id == mention.id
    end

    describe "topic feed isolation" do
      # Mirrors what the live composer assembles in
      # bonfire_ui_groups/.../group_live.sface (smart_input_opts) when posting in a topic/group.
      defp publish_in_category!(user, category) do
        boundaries =
          Bonfire.Classify.Boundaries.read_default_content_visibility(category)
          |> List.wrap()
          |> Enum.reject(&is_nil/1)

        boundaries = if boundaries == [], do: ["public"], else: boundaries

        {:ok, post} =
          Posts.publish(
            current_user: user,
            post_attrs: %{post_content: %{html_body: "<p>#{Bonfire.Common.Simulation.summary()}</p>"}},
            context_id: id(category),
            mentions: [id(category)],
            to_circles: Bonfire.Classify.Boundaries.post_circles_for_group(category),
            to_boundaries: boundaries
          )

        post
      end

      # Mirrors the assigns the live handler builds at handle_params/3 for the
      # "discussions" tab on a topic page (Bonfire.Classify.LiveHandler).
      defp topic_feed_filters(topic) do
        topic = repo().preload(topic, :character)
        feed_ids = Categories.group_feed_ids(topic, [])
        {:recent_discussions, %{feed_ids: feed_ids}}
      end

      test "first page contains only the topic's own posts" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)
        planning = fake_category!(creator, group, %{type: :topic})
        other_topic = fake_category!(creator, group, %{type: :topic})

        in_planning = publish_in_category!(creator, planning)
        in_other = publish_in_category!(creator, other_topic)
        in_group = publish_in_category!(creator, group)

        {feed_name, filters} = topic_feed_filters(planning)

        %{edges: edges} =
          FeedLoader.feed(feed_name, filters, current_user: creator)

        ids = Enum.map(edges, & &1.activity.object_id)

        assert in_planning.id in ids,
               "expected topic post in topic feed, got #{inspect(ids)}"

        refute in_other.id in ids,
               "topic feed leaked sibling-topic post #{in_other.id}"

        refute in_group.id in ids,
               "topic feed leaked parent-group post #{in_group.id}"
      end

      test "paginated topic feed (page 2) contains only the topic's own posts" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)
        planning = fake_category!(creator, group, %{type: :topic})
        other_topic = fake_category!(creator, group, %{type: :topic})

        # Generate enough posts to force pagination across all three contexts.
        # The interleaving matters: pagination cursors are ULIDs, so a leak is
        # more likely to surface when page 1's cursor lands inside a window
        # where parent/sibling posts dominate.
        all_posts =
          for _ <- 1..15 do
            [
              {:planning, publish_in_category!(creator, planning)},
              {:other, publish_in_category!(creator, other_topic)},
              {:group, publish_in_category!(creator, group)}
            ]
          end
          |> List.flatten()

        planning_ids =
          all_posts |> Enum.filter(&(elem(&1, 0) == :planning)) |> Enum.map(&elem(&1, 1).id)

        leak_ids =
          all_posts
          |> Enum.filter(&(elem(&1, 0) in [:other, :group]))
          |> Enum.map(&elem(&1, 1).id)

        {feed_name, filters} = topic_feed_filters(planning)

        # Page 1: small limit so we *must* paginate.
        page1 =
          FeedLoader.feed(feed_name, filters,
            current_user: creator,
            paginate: [limit: 5]
          )

        page1_ids = Enum.map(page1.edges, & &1.activity.object_id)

        for id <- page1_ids do
          assert id in planning_ids, "page 1 leaked non-topic post: #{id}"
        end

        # Page 2: same filters + before cursor (matches what
        # FeedLive's "load_more_newer" handler does via paginate_feed/4).
        cursor = e(page1.page_info, :after, nil) || e(page1.page_info, :end_cursor, nil)
        assert is_binary(cursor), "expected a pagination cursor on page 1"

        page2 =
          FeedLoader.feed(feed_name, filters,
            current_user: creator,
            paginate: [limit: 5, after: cursor]
          )

        page2_ids = Enum.map(page2.edges, & &1.activity.object_id)

        leaked = Enum.filter(page2_ids, &(&1 in leak_ids))

        assert leaked == [],
               """
               page 2 of topic feed leaked #{length(leaked)} non-topic post(s):
                 leaked ids: #{inspect(leaked)}
                 page2 ids:  #{inspect(page2_ids)}
                 expected only ids from: #{inspect(planning_ids)}
               """
      end

      test "load_more click opts shape: matches Bonfire.Social.Feeds.LiveHandler.paginate_opts/3" do
        # Builds the *exact* opts shape that Bonfire.Social.Feeds.LiveHandler.paginate_opts/3
        # constructs when a user clicks "Load more" on the topic page (see
        # bonfire_ui_social/.../components/paginate/load_more_live.sface +
        # feeds_live_handler.ex's `handle_event("load_more", ...)`).
        # If the topic feed leaks parent/sibling posts only via this path, this is
        # where it'll surface.
        creator = Fake.fake_user!()
        group = fake_group!(creator)
        planning = fake_category!(creator, group, %{type: :topic})
        sibling = fake_category!(creator, group, %{type: :topic})

        all_posts =
          for _ <- 1..15 do
            [
              {:planning, publish_in_category!(creator, planning)},
              {:sibling, publish_in_category!(creator, sibling)},
              {:group, publish_in_category!(creator, group)}
            ]
          end
          |> List.flatten()

        planning_ids =
          all_posts |> Enum.filter(&(elem(&1, 0) == :planning)) |> Enum.map(&elem(&1, 1).id)

        leak_ids =
          all_posts
          |> Enum.filter(&(elem(&1, 0) in [:sibling, :group]))
          |> Enum.map(&elem(&1, 1).id)

        {feed_name, raw_filters} = topic_feed_filters(planning)

        # Validate filters as the LV does on first load.
        {:ok, _preset, validated_filters} =
          FeedLoader.prepare_feed_preset_and_filters(
            Map.put(raw_filters, :feed_name, feed_name),
            current_user: creator
          )

        # Page 1: same call shape FeedLoader.feed/3 receives from
        # paginate_fetch_assign_feed/3. limit=4 forces multiple pages.
        page1_opts = [
          current_user: creator,
          feed_filters: validated_filters,
          paginate: [limit: 4]
        ]

        page1 = FeedLoader.feed(feed_name, validated_filters, page1_opts)

        page1_ids = Enum.map(page1.edges, & &1.activity.object_id)

        for id <- page1_ids do
          assert id in planning_ids, "page 1 leaked non-topic post: #{id}"
        end

        cursor = e(page1.page_info, :after, nil) || e(page1.page_info, :end_cursor, nil)
        assert is_binary(cursor), "expected pagination cursor on page 1"

        # Page 2..N: keep paginating, like the user repeatedly clicking "load more".
        # Each call passes the same validated_filters + a `paginate` keyword with
        # the new `after` cursor — exactly what paginate_fetch_assign_feed does.
        {all_seen, _final_cursor} =
          Enum.reduce_while(1..6, {page1_ids, cursor}, fn _page, {acc_ids, cur} ->
            opts = [
              current_user: creator,
              feed_filters: validated_filters,
              paginate: [limit: 4, after: cur]
            ]

            page = FeedLoader.feed(feed_name, validated_filters, opts)
            ids = Enum.map(page.edges, & &1.activity.object_id)

            next_cursor = e(page.page_info, :after, nil) || e(page.page_info, :end_cursor, nil)

            cond do
              ids == [] -> {:halt, {acc_ids, cur}}
              is_nil(next_cursor) -> {:halt, {acc_ids ++ ids, nil}}
              true -> {:cont, {acc_ids ++ ids, next_cursor}}
            end
          end)

        leaked = Enum.filter(all_seen, &(&1 in leak_ids))

        assert leaked == [],
               """
               topic feed leaked #{length(leaked)} non-topic post(s) over paginated calls:
                 leaked ids: #{inspect(Enum.uniq(leaked))}
                 all seen:   #{inspect(all_seen)}
                 expected only ids from: #{inspect(planning_ids)}
               """
      end

      test "paginating with the FeedFilters struct stored in assigns (mirrors LV flow)" do
        # The LV stores a *validated* %FeedFilters{} struct in assigns after the
        # first load (see Bonfire.UI.Social.LiveHandler.feed_assigns/2 →
        # merge_feed_assigns). Subsequent paginate_feed calls re-use that struct.
        # This mirrors that flow to catch a regression where the validated struct
        # silently drops :feed_ids on the second call.
        creator = Fake.fake_user!()
        group = fake_group!(creator)
        planning = fake_category!(creator, group, %{type: :topic})
        other_topic = fake_category!(creator, group, %{type: :topic})

        all_posts =
          for _ <- 1..15 do
            [
              {:planning, publish_in_category!(creator, planning)},
              {:other, publish_in_category!(creator, other_topic)},
              {:group, publish_in_category!(creator, group)}
            ]
          end
          |> List.flatten()

        planning_ids =
          all_posts |> Enum.filter(&(elem(&1, 0) == :planning)) |> Enum.map(&elem(&1, 1).id)

        leak_ids =
          all_posts
          |> Enum.filter(&(elem(&1, 0) in [:other, :group]))
          |> Enum.map(&elem(&1, 1).id)

        {feed_name, raw_filters} = topic_feed_filters(planning)

        # Step 1: validate filters the way prepare_feed_preset_and_filters does
        # at first load, producing the %FeedFilters{} struct that the LV stores.
        {:ok, _preset, validated_filters} =
          FeedLoader.prepare_feed_preset_and_filters(
            Map.put(raw_filters, :feed_name, feed_name),
            current_user: creator
          )

        # Sanity: the prepared struct must still carry our feed_ids.
        assert validated_filters.feed_ids == raw_filters.feed_ids,
               "feed_ids dropped during prepare_feed_preset_and_filters: #{inspect(validated_filters)}"

        # Step 2: page 1 using the validated struct (as FeedLoader.feed/2 expects).
        page1 =
          FeedLoader.feed(validated_filters,
            current_user: creator,
            paginate: [limit: 5]
          )

        page1_ids = Enum.map(page1.edges, & &1.activity.object_id)

        for id <- page1_ids do
          assert id in planning_ids, "page 1 (validated filters) leaked non-topic post: #{id}"
        end

        cursor = e(page1.page_info, :after, nil) || e(page1.page_info, :end_cursor, nil)
        assert is_binary(cursor), "expected a pagination cursor on page 1"

        # Step 3: page 2 with the *same* validated struct + cursor.
        page2 =
          FeedLoader.feed(validated_filters,
            current_user: creator,
            paginate: [limit: 5, after: cursor]
          )

        page2_ids = Enum.map(page2.edges, & &1.activity.object_id)

        leaked = Enum.filter(page2_ids, &(&1 in leak_ids))

        assert leaked == [],
               """
               page 2 (validated filters) leaked #{length(leaked)} non-topic post(s):
                 leaked ids: #{inspect(leaked)}
                 page2 ids:  #{inspect(page2_ids)}
                 expected only ids from: #{inspect(planning_ids)}
               """
      end
    end
  end
end
