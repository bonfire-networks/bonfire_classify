if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupPostMentionNotifyTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Me.Fake
    alias Bonfire.Social.Feeds

    # The group composer (see group_live.sface) injects the group's own id into `mentions`
    # as a bare id string — unlike text @-mentions, which the tag parser resolves to loaded
    # structs. When publishing with the "local" boundary, `Feeds.users_to_notify/3` fed that
    # bare id straight into `repo().maybe_preload/2`, which raised `BadMapError: expected a
    # map, got "01K..."`, aborting the whole post publish.
    test "notify resolution tolerates a bare-id mention (e.g. a group posting to itself)" do
      me = Fake.fake_user!()
      group = fake_group!(me)
      group_id = id(group)

      # bare id in mentions + "local" boundary == what the group composer sends
      assert %{notify_feeds: notify_feeds, notify_emails: notify_emails} =
               Feeds.reply_and_or_mentions_to_notify(
                 me,
                 "local",
                 [group_id],
                 nil,
                 [group_id]
               )

      # the group id is not a user, so nobody is notified — the point is it must not crash
      assert is_list(notify_feeds)
      assert is_list(notify_emails)
    end
  end
end
