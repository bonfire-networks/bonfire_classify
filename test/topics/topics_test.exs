if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.TopicTagMentionsTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Posts
    alias Bonfire.Social.FeedActivities

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
  end
end
