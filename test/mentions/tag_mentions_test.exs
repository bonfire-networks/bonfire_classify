defmodule Bonfire.Classify.TagMentionsTest do
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Posts
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedActivities

  alias Bonfire.Me.Fake
  import Bonfire.Boundaries.Debug

  test "can post with a mention" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    msg = "+#{mentioned.character.username} you have an epic text message"
    attrs = %{post_content: %{html_body: msg}}

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    # debug(post.post_content.html_body)
    assert String.contains?(post.post_content.html_body, "epic text message")

    assert String.contains?(
             post.post_content.html_body,
             "+#{mentioned.character.username}"
           )
  end

  # test "can see post mentioning a category in its notifications (using the 'mentions' preset), ignoring boundaries" do
  #   me = Fake.fake_user!()
  #   other = Fake.fake_user!()
  #   mentioned = fake_category!(other)
  #   attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
  #   assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
  #   assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: mentioned, skip_boundary_check: true)
  #   # debug(feed)
  #   assert %{} = fp = List.first(feed)
  #   assert fp.activity.object_id == mention.id
  # end

  # test "can see post mentioning a category in its notifications feed (using the 'mentions' preset), with boundaries enforced" do
  #   me = Fake.fake_user!()
  #   other = Fake.fake_user!()
  #   mentioned = fake_category!(other)
  #   attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
  #   assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
  #   assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: mentioned)
  #   assert %{} = fp = List.first(feed)
  #   assert fp.activity.object_id == mention.id
  # end

  # test "mentioning a category (which I don't have tag permission on) appears in its notifications feed, if using the 'mentions' preset" do
  #   me = Fake.fake_user!()
  #   other = Fake.fake_user!()
  #   mentioned = fake_category!(other)
  #   attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
  #   assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
  #   debug_my_grants_on(mentioned, mention)
  #   assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: mentioned)
  #   assert %{} = fp = List.first(feed)
  #   assert fp.activity.object_id == mention.id
  # end

  test "mentioning a category appears in its outbox feed, if using the 'mentions' preset" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)

    attrs = %{
      post_content: %{
        html_body: "+#{mentioned.character.username} this is very on topic</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    # debug_my_grants_on(mentioned, mention)

    assert %{edges: feed} = FeedActivities.feed(:outbox, current_user: mentioned)

    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "mentioning a category appears in my own notifications, if I have :create permission on it" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)

    attrs = %{
      post_content: %{
        html_body: "+#{mentioned.character.username} this is very on topic</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    assert %{edges: []} = FeedActivities.feed(:notifications, current_user: me)
  end

  test "mentioning a category does NOT appear in my own notifications, if I don't have permission" do
    me = Fake.fake_user!()
    other = Fake.fake_user!()
    mentioned = fake_category!(other, nil, %{boundary: "mentions"})

    attrs = %{
      post_content: %{
        html_body: "+#{mentioned.character.username} this is very on topic</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "mentions"
             )

    assert %{edges: []} = FeedActivities.feed(:notifications, current_user: me)
  end

  test "mentioning a category appears in my instance feed (if using 'local' preset)" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)

    attrs = %{
      post_content: %{
        html_body: "+#{mentioned.character.username} this is very on topic</p>"
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

  test "mentioning a category does not appear in a 3rd party's instance feed (if not included in circles)" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)

    attrs = %{
      post_content: %{
        html_body: "+#{mentioned.character.username} this is very on topic</p>"
      }
    }

    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)
    third = Fake.fake_user!()
    assert %{edges: []} = FeedActivities.feed(:local, current_user: third)
  end

  test "mentioning a category with 'local' preset does not appear *publicly* in the instance feed" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)

    attrs = %{
      post_content: %{
        html_body: "+#{mentioned.character.username} this is very on topic</p>"
      }
    }

    assert {:ok, mention} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "local"
             )

    assert %{edges: []} = FeedActivities.feed(:local)
  end
end
