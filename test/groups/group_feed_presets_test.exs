if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupFeedPresetsTest do
    @moduledoc """
    The "My groups" and "All known groups" feeds: the activities in the outboxes of groups and their topics, as the group pages show them, for the groups the viewer joined or for every group and topic this instance knows.

    Both scope themselves through the `in_groups` filter, which `Bonfire.Classify.FeedFilters` applies, so these tests drive the presets the way the feed page does, by name.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    @moduletag :backend

    @open_group %{
      membership: "open",
      visibility: "global",
      participation: "anyone",
      default_content_visibility: "public"
    }

    alias Bonfire.Classify.Categories
    alias Bonfire.Me.Fake
    alias Bonfire.Social.FeedLoader
    alias Bonfire.Social.FeedFilters
    alias Bonfire.Social.Graph.Follows

    setup do
      # TEMP: until we work on group federation
      Process.put(:federating, false)
      # ensure boundary preloads run synchronously in feed prep
      Process.put([:bonfire, :feed_live_update_many_preload_mode], :inline)

      user = Fake.fake_user!()
      creator_a = Fake.fake_user!()
      creator_b = Fake.fake_user!()
      followed = Fake.fake_user!()

      # open and public, since a group made with no dimensions reviews joins and would leave the join a request
      group_a = fake_group!(creator_a, @open_group)
      group_b = fake_group!(creator_b, @open_group)
      topic_a = fake_category!(creator_a, group_a, %{type: :topic})

      # membership alone, with no follow, so what the feed shows comes from joining
      {:ok, _} = Categories.join_group(user, group_a)
      {:ok, _} = Follows.follow(user, followed)

      post_a = fake_post_in_group!(creator_a, group_a, "<p>in group A</p>")
      post_topic_a = fake_post_in_group!(creator_a, topic_a, "<p>in a topic of A</p>")
      post_b = fake_post_in_group!(creator_b, group_b, "<p>in group B</p>")
      post_followed = Bonfire.Posts.Fake.fake_post!(followed, "public")

      assert Categories.member_of_groups?(user, [id(group_a)]) == %{id(group_a) => true},
             "control: the join made the user a member, not a requester"

      assert {:ok, _, %{id: group_b_id}} = Categories.group_of_object(post_b)
      assert group_b_id == id(group_b), "control: the post in B is in B"

      {:ok,
       user: user,
       creator_a: creator_a,
       creator_b: creator_b,
       group_a: group_a,
       group_b: group_b,
       post_a: post_a,
       post_topic_a: post_topic_a,
       post_b: post_b,
       post_followed: post_followed}
    end

    defp feed_edges(preset, opts) do
      %{edges: edges} = FeedLoader.feed(preset, Keyword.put(opts, :paginate, limit: 10))
      edges
    end

    defp filtered_edges(preset, filters, opts) do
      %{edges: edges} = FeedLoader.feed(preset, filters, Keyword.put(opts, :paginate, limit: 10))
      edges
    end

    defp in_edges?(edges, post), do: FeedLoader.feed_contains?(edges, post) != false

    test "the in_groups key is a field on FeedFilters" do
      assert :in_groups in FeedFilters.supported_filters()
    end

    test "Bonfire.Classify.FeedFilters is registered" do
      assert Bonfire.Classify.FeedFilters in Bonfire.Common.FeedFilterModule.modules()
    end

    test "in_groups takes a scope and an origin" do
      assert {:ok, %FeedFilters{in_groups: [:all, :remote]}} =
               FeedFilters.validate(%{in_groups: [:all, :remote]})

      assert {:ok, %FeedFilters{in_groups: [:joined]}} = FeedFilters.validate(%{in_groups: :joined}),
             "a bare scope still works, as the presets and saved filters have it"
    end

    # `:feed_ids` says the caller already gives the groups' outboxes in `feed_ids`, as /groups does with the ones it holds, so the clause adds no subquery of its own
    test "in_groups: [:feed_ids] adds no group subquery", ctx do
      require Ecto.Query
      base = Ecto.Query.from(fp in Bonfire.Data.Social.FeedPublish, as: :main_object)
      sql = fn query -> elem(Ecto.Adapters.SQL.to_sql(:all, Bonfire.Common.Repo, query), 0) end

      joined_sql =
        sql.(Bonfire.Classify.FeedFilters.maybe_filter(base, {:in_groups, [:joined]}, current_user: ctx.user))

      assert joined_sql != sql.(base), "control: the joined scope adds its subquery"

      assert sql.(
               Bonfire.Classify.FeedFilters.maybe_filter(base, {:in_groups, [:feed_ids]},
                 current_user: ctx.user
               )
             ) == sql.(base)
    end

    test "My groups with in_groups: [:feed_ids] shows the posts in the given outboxes", ctx do
      outbox_ids = Bonfire.Common.Repo.all(Categories.group_outbox_ids_query({:joined, ctx.user}))
      assert outbox_ids != [], "control: the user's groups have outboxes"

      edges =
        filtered_edges(:my_groups, %{in_groups: [:feed_ids], feed_ids: outbox_ids},
          current_user: ctx.user
        )

      assert in_edges?(edges, ctx.post_a), "a post in a group I joined"
      assert in_edges?(edges, ctx.post_topic_a), "a post in a topic of a group I joined"
      refute in_edges?(edges, ctx.post_b), "a post in a group I did not join"
      refute in_edges?(edges, ctx.post_followed), "a plain post by someone I follow"
    end

    # where the group is hosted, as the /groups origin menu means it; these groups are all local
    for {scope, preset} <- [joined: :my_groups, all: :known_groups] do
      test "in_groups with :local keeps a local group's posts, and with :remote leaves them out (#{scope})",
           ctx do
        scope = unquote(scope)
        preset = unquote(preset)

        local_edges = filtered_edges(preset, %{in_groups: [scope, :local]}, current_user: ctx.user)

        assert in_edges?(local_edges, ctx.post_a), "a post in a local group"
        assert in_edges?(local_edges, ctx.post_topic_a), "a post in a local topic"

        remote_edges =
          filtered_edges(preset, %{in_groups: [scope, :remote]}, current_user: ctx.user)

        refute in_edges?(remote_edges, ctx.post_a), "a local group is not from other instances"
        refute in_edges?(remote_edges, ctx.post_topic_a), "a topic counts by its own origin"
      end
    end

    test "My groups shows the groups I joined, not groups I only see nor people I follow", ctx do
      edges = feed_edges(:my_groups, current_user: ctx.user)

      assert in_edges?(edges, ctx.post_a), "the post in a group I joined"
      assert in_edges?(edges, ctx.post_topic_a), "the post in a topic of a group I joined"
      refute in_edges?(edges, ctx.post_b), "a post in a group I can see but did not join"
      refute in_edges?(edges, ctx.post_followed), "a plain post by someone I follow"
    end

    test "All known groups shows posts in every group and topic I can read, and nothing outside them",
         ctx do
      topic_b = fake_category!(ctx.creator_b, ctx.group_b, %{type: :topic})
      post_topic_b = fake_post_in_group!(ctx.creator_b, topic_b, "<p>in a topic of B</p>")

      creator_t = Fake.fake_user!()
      standalone_topic = fake_category!(creator_t, nil, %{type: :topic})
      post_t = fake_post_in_group!(creator_t, standalone_topic, "<p>in a standalone topic</p>")

      assert Bonfire.Social.Boosts.boosted?(standalone_topic, post_t),
             "control: the post is in the standalone topic's outbox"

      creator_c = Fake.fake_user!()
      hidden_group = fake_group!(creator_c, %{visibility: "members:private"})
      post_c = fake_post_in_group!(creator_c, hidden_group, "<p>in a hidden group</p>")

      creator_d = Fake.fake_user!()
      archived_group = fake_group!(creator_d, @open_group)
      post_d = fake_post_in_group!(creator_d, archived_group, "<p>in an archived group</p>")

      assert FeedLoader.feed_contains?(:known_groups, post_d, current_user: ctx.user),
             "control: the post is in All known groups before its group is archived"

      assert {:ok, _} = Categories.soft_delete(archived_group, creator_d)

      edges = feed_edges(:known_groups, current_user: ctx.user)

      assert in_edges?(edges, ctx.post_a), "a post in a group I joined"
      assert in_edges?(edges, ctx.post_b), "a post in a group I did not join"
      assert in_edges?(edges, post_topic_b), "a post in a topic of a group I did not join"
      assert in_edges?(edges, post_t), "a post in a topic that sits in no group"

      assert FeedLoader.feed_contains?(:known_groups, post_c, current_user: creator_c),
             "control: the hidden group's post is in All known groups for its member"

      refute in_edges?(edges, post_c), "a post in a hidden group I am not in"
      refute in_edges?(edges, post_d), "a post in an archived group"
      refute in_edges?(edges, ctx.post_followed), "a plain post by someone I follow"

      refute FeedLoader.feed_contains?(:my_groups, post_t, current_user: ctx.user),
             "a standalone topic has no group to be a member of, so it is not in My groups"

      guest_edges = feed_edges(:known_groups, [])
      assert in_edges?(guest_edges, ctx.post_b), "a guest sees a public group's post"
    end

    # at the test page size of 2, so the third post is on the next page, which is where the deferred join can come back empty before moving on
    for preset <- [:my_groups, :known_groups] do
      test "#{preset} pages through posts in three groups" do
        preset = unquote(preset)
        reader = Fake.fake_user!()
        creator = Fake.fake_user!()

        [post_1, post_2, post_3] =
          for n <- 1..3 do
            group = fake_group!(creator, @open_group)
            {:ok, _} = Categories.join_group(reader, group)
            fake_post_in_group!(creator, group, "<p>post #{n}</p>")
          end

        %{edges: page_1, page_info: page_info} = FeedLoader.feed(preset, current_user: reader)

        assert in_edges?(page_1, post_3)
        assert in_edges?(page_1, post_2)
        assert length(page_1) == 2
        refute in_edges?(page_1, post_1)

        assert cursor = e(page_info, :end_cursor, nil)

        %{edges: page_2} = FeedLoader.feed(preset, current_user: reader, after: cursor)

        assert in_edges?(page_2, post_1), "the third post is after the cursor"
        refute in_edges?(page_2, post_2)
        refute in_edges?(page_2, post_3)
      end

      test "#{preset} shows a thread once when it has a reply", ctx do
        preset = unquote(preset)
        root = ctx.post_a

        {:ok, reply} =
          Bonfire.Posts.publish(
            current_user: ctx.creator_a,
            post_attrs: %{
              reply_to_id: root.id,
              post_content: %{html_body: "<p>a reply in group A</p>"}
            },
            publish_in: ctx.group_a.id,
            boundary: Bonfire.Classify.Boundaries.read_default_content_visibility(ctx.group_a)
          )

        assert Bonfire.Social.Boosts.boosted?(ctx.group_a, reply),
               "control: the reply is in the group's outbox as well as its root"

        edges = feed_edges(preset, current_user: ctx.user)

        thread_edges =
          Enum.filter(edges, &(e(&1, :activity, :object_id, nil) in [root.id, reply.id]))

        assert length(thread_edges) == 1,
               "the thread should show once, got #{length(thread_edges)}"
      end
    end
  end
end
