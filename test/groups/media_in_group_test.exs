defmodule Bonfire.Classify.MediaInGroupTest do
  @moduledoc """
  Media published into a group, which reaches the group's feed by a different route than a post does.

  A group's feed shows what the GROUP posted or boosted, so anything else gets there by the group auto-boosting it. That auto-boost is arranged by `Bonfire.Tag.Acts.Tag`, an epic act — and media does not run an epic: `Bonfire.Files.Media.publish/3` goes straight to `Bonfire.Social.Objects.publish/5`, which sets boundaries and files a feed activity, with no tagging step.

  So a post carrying media is fine (the post runs the epic), while standalone media is not. That is reachable today through the GraphQL upload API, which publishes media on its own when given a boundary.
  """
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  alias Bonfire.Classify.Simulate
  alias Bonfire.Social.FeedLoader

  defp public_group(creator) do
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.apply(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    group
  end

  defp in_group_feed?(object, group) do
    !!FeedLoader.feed_contains?(:user_activities, object, by: group, current_user: group)
  end

  test "a post carrying media reaches the group's feed" do
    creator = Bonfire.Me.Fake.fake_user!()
    group = public_group(creator)

    media = Bonfire.Social.Fake.upload_media(:images, creator, "in a group")

    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{
                 post_content: %{html_body: "<p>a photo for the group</p>"},
                 uploaded_media: [media],
                 context_id: uid(group),
                 mentions: [uid(group)]
               },
               boundary: "public",
               context_id: uid(group),
               mentions: [uid(group)]
             )

    assert in_group_feed?(post, group),
           "a post runs the publish epic, so the Tag act boosts it into the group"
  end

  # Fixed 2026-09-02, having found two problems rather than one:
  #   1. naming a context CRASHED — `set_boundaries/4` handed a bare `context_id` to
  #      `Feeds.feed_ids/2`, whose list clause preloaded it and raised `BadMapError`. That was a
  #      lurking bug for ANY caller naming a context, not only for groups, and is fixed in the list
  #      clause: ids are left for `feed_id/2` to resolve, structs are still preloaded in one call.
  #   2. media runs no epic, so `Bonfire.Tag.Acts.Tag` never tagged or boosted it. `Media.publish/3`
  #      now calls `Bonfire.Tag.maybe_tag/4`, which tags AND auto-boosts category tags with the same
  #      `:tag` permission check, and is built for use outside an epic.
  # Reachable through the GraphQL upload API, which calls `Media.publish/3` when given a boundary.
  test "media published on its own reaches the group's feed too" do
    creator = Bonfire.Me.Fake.fake_user!()
    group = public_group(creator)

    media = Bonfire.Social.Fake.upload_media(:images, creator, "standalone in a group")

    assert {:ok, _activity} =
             Bonfire.Files.Media.publish(creator, media,
               boundary: "public",
               context_id: uid(group),
               mentions: [uid(group)]
             )

    assert in_group_feed?(media, group),
           "media addressed to a group belongs in that group, whether or not a post carries it"
  end
end
