defmodule Bonfire.Classify.PublishInGroupTest do
  @moduledoc """
  `publish_in`: saying which group something belongs to, rather than making us work it out.

  A group shows an object once the GROUP boosts it, which `Bonfire.Tag.Acts.Tag` arranges. It can derive the group from the thread being replied to, and does so for anything that arrives without one (an API client, a federated activity). A caller that already knows — the composer holds it in its assigns for free — should say so instead, and then nothing is looked up.

  These pin the contract the composer submits against, and the fact that it is NOT reply-only: publishing straight into a group is the same statement about the same field.
  """
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  alias Bonfire.Classify.Simulate
  alias Bonfire.Social.FeedLoader

  defp public_group(creator) do
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
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

  # a group that doesn't federate caps a `public` post to `nonfederated` (Q13, see `group_post_audience_test.exs`), so there's no Announce to send for it; a user boosting it still boosts it locally
  test "a user can boost a post in a group that doesn't federate, without it being announced" do
    author = Bonfire.Me.Fake.fake_user!()
    booster = Bonfire.Me.Fake.fake_user!()
    group = Simulate.fake_group!(author, %{membership: "local:members", visibility: "local"})

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        boundary: "public",
        publish_in: group.id,
        post_attrs: %{post_content: %{html_body: "in a group for users of this instance"}}
      )

    refute Bonfire.Boundaries.object_public?(post), "control: the group's cap keeps it off the wire"
    assert {:ok, boost} = Bonfire.Social.Boosts.boost(booster, post)
    assert {:error, :not_found} = ActivityPub.Object.get_cached(pointer: boost), "not announced"
  end

  test "a post published with `publish_in` reaches that group, without naming it any other way" do
    creator = Bonfire.Me.Fake.fake_user!()
    group = public_group(creator)

    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: "<p>straight into the group</p>"}},
               boundary: "public",
               publish_in: uid(group)
             )

    assert in_group_feed?(post, group),
           "`publish_in` is the whole statement: no `context_id`, no mention of the group, no thread to derive from"
  end

  test "a reply published with `publish_in` reaches that group" do
    creator = Bonfire.Me.Fake.fake_user!()
    group = public_group(creator)

    assert {:ok, thread_starter} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: "<p>a thread</p>"}},
               boundary: "public",
               publish_in: uid(group)
             )

    replier = Bonfire.Me.Fake.fake_user!()

    assert {:ok, reply} =
             Bonfire.Posts.publish(
               current_user: replier,
               post_attrs: %{
                 post_content: %{html_body: "<p>a reply</p>"},
                 reply_to_id: uid(thread_starter)
               },
               boundary: "public",
               publish_in: uid(group)
             )

    assert in_group_feed?(reply, group),
           "the caller named the group, so it is used as given rather than re-derived from the thread"
  end

  # The derivation exists for callers that DON'T know. This is the same reply without `publish_in`,
  # and it must land in the same place — otherwise the composer and the APIs disagree about where a
  # reply belongs, which is the bug this whole thread of work started from.
  test "and a reply without `publish_in` still reaches it, derived from the thread" do
    creator = Bonfire.Me.Fake.fake_user!()
    group = public_group(creator)

    assert {:ok, thread_starter} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: "<p>a thread</p>"}},
               boundary: "public",
               publish_in: uid(group)
             )

    replier = Bonfire.Me.Fake.fake_user!()

    assert {:ok, reply} =
             Bonfire.Posts.publish(
               current_user: replier,
               post_attrs: %{
                 post_content: %{html_body: "<p>a reply that says nothing about the group</p>"},
                 reply_to_id: uid(thread_starter)
               },
               boundary: "public"
             )

    assert in_group_feed?(reply, group),
           "a reply belongs to its thread's group whether or not the caller knew to say so"
  end
end
