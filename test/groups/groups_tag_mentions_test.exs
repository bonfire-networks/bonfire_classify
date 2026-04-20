if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupTagMentionsTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Posts
    alias Bonfire.Social.FeedActivities

    alias Bonfire.Me.Fake

    test "mentioning a group appears in its outbox feed" do
      me = Fake.fake_user!()
      group = fake_group!(me)

      attrs = %{
        post_content: %{
          html_body: "@#{group.character.username} this is very on topic"
        }
      }

      assert {:ok, mention} =
               Posts.publish(
                 current_user: me,
                 post_attrs: attrs
               )

      assert %{edges: feed} =
               FeedActivities.feed(:user_activities, by: group, current_user: me)

      assert %{} = fp = List.first(feed)
      assert fp.activity.object_id == mention.id
    end

    test "mentioning a non-public group does not appear in a 3rd party's instance feed" do
      me = Fake.fake_user!()
      group = fake_group!(me)

      attrs = %{
        post_content: %{
          html_body: "@#{group.character.username} this is very on topic"
        }
      }

      assert {:ok, mention} = Posts.publish(current_user: me, post_attrs: attrs)

      third = Fake.fake_user!()
      refute Bonfire.Social.FeedLoader.feed_contains?(:local, mention, current_user: third)
    end

    test "mentioning a non-public group does not appear publicly (for guests)" do
      me = Fake.fake_user!()
      group = fake_group!(me)

      attrs = %{
        post_content: %{
          html_body: "@#{group.character.username} this is very on topic"
        }
      }

      assert {:ok, mention} =
               Posts.publish(
                 current_user: me,
                 post_attrs: attrs
               )

      refute Bonfire.Social.FeedLoader.feed_contains?(:local, mention)
    end
  end
end
