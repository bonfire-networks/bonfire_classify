defmodule Bonfire.Classify.TagMentionsTest do
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.{Posts, Feeds, FeedActivities}
  alias Bonfire.Me.Fake
  import Bonfire.Boundaries.Debug

  test "can post with a mention" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    msg = "+#{mentioned.character.username} you have an epic text message"
    attrs = %{post_content: %{html_body: msg}}
    assert {:ok, post} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    dump(post.post_content.html_body)
    assert String.contains?(post.post_content.html_body, "epic text message")
    assert String.contains?(post.post_content.html_body, "+#{mentioned.character.username}")
  end

  test "can see post mentioning  a category in its notifications (using the 'mentions' preset), ignoring boundaries" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: mentioned, skip_boundary_check: true)
    # debug(feed)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "can see post mentioning a category in its notifications feed (using the 'mentions' preset), with boundaries enforced" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: mentioned)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "mentioning a category does not appear in my own notifications" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    assert %{edges: []} = FeedActivities.feed(:notifications, current_user: me)
  end

  test "mentioning a category else does not appear in a 3rd party's notifications" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    third = Fake.fake_user!()
    assert %{edges: []} = FeedActivities.feed(:notifications, current_user: third)
  end

  test "mentioning a category appears in their notifications feed, if using the 'mentions' preset" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    debug_my_grants_on(mentioned, mention)
    assert %{edges: feed} = FeedActivities.feed(:notifications, current_user: mentioned)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "mentioning a category does not appear in their home feed, if they don't follow me, and have disabled notifications in home feed" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}

    {:ok, %{assign_context: assigns}} = Bonfire.Me.Settings.put([Bonfire.Social.Feeds, :my_feed_includes, :notifications], false, current_user: mentioned)
    # |> info("change settings")
    mentioned = assigns[:current_user] || mentioned # user with updated settings

    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    assert %{edges: []} = FeedActivities.my_feed(mentioned)
  end

  test "mentioning a category appears in their home feed, if they don't follow me, and have enabled notifications in home feed" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}

    # Bonfire.Me.Settings.put([Bonfire.Social.Feeds, :my_feed_includes, :notifications], true, current_user: mentioned) # default anyway

    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "mentions")
    assert %{edges: feed} = FeedActivities.my_feed(mentioned)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "mentioning a category DOES NOT appear (if NOT using the preset 'mentions' boundary) in their instance feed" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)
    assert %{edges: []} = FeedActivities.feed(:local, current_user: mentioned)
  end

  test "mentioning a category appears in my instance feed (if using 'local' preset)" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "local")
    assert %{edges: feed} = FeedActivities.feed(:local, current_user: me)
    assert %{} = fp = List.first(feed)
    assert fp.activity.object_id == mention.id
  end

  test "mentioning a category does not appear in a 3rd party's instance feed (if not included in circles)" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)
    third = Fake.fake_user!()
    assert %{edges: []} = FeedActivities.feed(:local, current_user: third)
  end

  test "mentioning a category with 'local' preset does not appear *publicly* in the instance feed" do
    me = Fake.fake_user!()
    mentioned = fake_category!(me)
    attrs = %{post_content: %{html_body: "+#{mentioned.character.username} this is very on topic</p>"}}
    assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs, boundary: "local")
    assert %{edges: []} = FeedActivities.feed(:local)
  end

end
