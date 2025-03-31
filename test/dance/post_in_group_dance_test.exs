if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.Dance.PostGroupTest do
    use Bonfire.Classify.ConnCase, async: false
    use Bonfire.Classify.SharedDataDanceCase
    use Bonfire.Common.Utils

    @moduletag :test_instance

    import Untangle
    import Bonfire.Common.Config, only: [repo: 0]
    import Bonfire.Classify.SharedDataDanceCase

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.AdapterUtils

    alias Bonfire.Posts
    alias Bonfire.Social.PostContents
    alias Bonfire.Social.Graph.Follows
    alias Bonfire.Social.FeedActivities

    @tag :test_instance
    test "can make a public post, and fetch it from AP API (both with AP ID and with friendly URL and Accept header)",
         context do
      user = context[:local][:user]

      group =
        fancy_fake_category!(user)
        |> debug("thegroup")

      id = id(group[:category])

      TestInstanceRepo.apply(fn ->
        Logger.metadata(action: "follow the group")

        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        remote_follower = context[:remote][:user]
        assert {:ok, follow} = Follows.follow(remote_follower, group_on_remote)
      end)

      # back to local

      Logger.metadata(action: "create local post 1")
      attrs = %{post_content: %{html_body: "test content one"}, context_id: id, mentions: [id]}

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: attrs,
          boundary: "public",
          context_id: id,
          mentions: [id]
        )

      assert %{edges: feed} = FeedActivities.feed(:user_activities, current_user: user)
      assert %{} = fp = List.first(feed)
      assert fp.activity.object_id == post.id

      assert %{edges: feed} =
               FeedActivities.feed(:user_activities, current_user: group[:category])

      assert %{} = fp = List.first(feed)
      assert fp.activity.object_id == post.id

      canonical_url =
        Bonfire.Common.URIs.canonical_url(post)
        |> info("canonical_url")

      # back to remote
      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        Logger.metadata(action: "check that post 1 was federated to group followers")

        assert %{edges: feed} =
                 FeedActivities.feed(:user_activities, current_user: group_on_remote)

        assert %{} = fp = List.first(feed)
        # |> IO.inspect
        assert fp.activity.object.post_content.html_body =~ attrs.post_content.html_body
        # a boost
        assert fp.activity.verb_id == "300ST0R0RANN0VCEANACT1V1TY"
      end)
    end
  end
end
