if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupFeedDedupTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Me.Fake
    alias Bonfire.Social.FeedLoader

    setup do
      # TEMP: until we work on group federation
      Process.put(:federating, false)
      # ensure boundary preloads run synchronously in feed prep
      Process.put(:feed_live_update_many_preload_mode, :inline)
      :ok
    end

    # When posting inside a group, two activities are created for the same object:
    #   1. the create (or reply) activity by the author
    #   2. the group's auto-boost of that object (see Bonfire.Social.Tags.auto_boost/2)
    # The "my" feed must collapse these into a single entry (mayel's fix in
    # `dedup feed by object`, FeedLoader.do_prepare_feed/4).

    defp object_occurrences(edges, object_id) do
      Enum.filter(edges, fn edge ->
        e(edge, :activity, :object_id, nil) == object_id or
          e(edge, :activity, :object, :id, nil) == object_id
      end)
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
