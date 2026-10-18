if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.TopicFollowTest do
    @moduledoc """
    A topic is followed rather than joined, so following one that people may read gives a follow: not a pending request, and not a refusal (reported on prod as "Could not follow" on a local topic).
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    @moduletag :backend

    alias Bonfire.Me.Fake
    alias Bonfire.Social.Graph.Follows

    setup do
      Process.put(:federating, false)
      owner = Fake.fake_user!()

      group =
        fake_group!(owner, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      topic = fake_category!(owner, group, %{type: :topic, name: "Planning"})
      {:ok, owner: owner, group: group, topic: topic}
    end

    test "a group member following a topic in it follows it", %{group: group, topic: topic} do
      member = Fake.fake_user!()
      assert {:ok, _} = Bonfire.Classify.Categories.join_group(member, group)

      assert {:ok, %Bonfire.Data.Social.Follow{}} = Follows.follow(member, topic)
      assert Follows.following?(member, topic)
    end

    test "someone who may read a topic in a public group follows it", %{topic: topic} do
      other = Fake.fake_user!()
      assert Bonfire.Boundaries.can?(other, :read, topic), "control: they may read it"

      assert {:ok, %Bonfire.Data.Social.Follow{}} = Follows.follow(other, topic)
      assert Follows.following?(other, topic)
    end

    # A members-only group's visibility grants nothing, so `:follow` on a topic in it can only come from the members circle, whose role carries none (prod: a moderator added by the group's owner got "Could not follow")
    test "a moderator added by the owner follows a topic in a members-only group" do
      owner = Fake.fake_user!()
      moderator = Fake.fake_user!()

      group =
        fake_group!(owner, %{
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members",
          default_content_visibility: "members:private"
        })

      topic = fake_category!(owner, group, %{type: :topic, name: "Members' corner"})

      assert {:ok, _} = Bonfire.Classify.Categories.add_moderator(owner, group, moderator)

      assert Bonfire.Boundaries.can?(moderator, :read, topic),
             "control: a moderator may read the topic"

      assert {:ok, %Bonfire.Data.Social.Follow{}} = Follows.follow(moderator, topic)
    end

    test "a member follows a topic in a members-only group, and an outsider can't" do
      owner = Fake.fake_user!()
      member = Fake.fake_user!()
      outsider = Fake.fake_user!()

      group =
        fake_group!(owner, %{
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members",
          default_content_visibility: "members:private"
        })

      topic = fake_category!(owner, group, %{type: :topic, name: "Members' corner"})

      assert {:ok, _} =
               Bonfire.Classify.Categories.add_member(owner, group, id(member),
                 skip_boundary_check: true
               )

      assert {:ok, %Bonfire.Data.Social.Follow{}} = Follows.follow(member, topic)

      refute match?({:ok, %Bonfire.Data.Social.Follow{}}, Follows.follow(outsider, topic)),
             "an outsider doesn't follow a members-only group's topic"
    end

    # a topic made before topics got the grant, reproduced by taking the grant away again
    test "the data migration lets members follow a members-only group's older topics" do
      owner = Fake.fake_user!()
      member = Fake.fake_user!()

      group =
        fake_group!(owner, %{
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members",
          default_content_visibility: "members:private"
        })

      topic = fake_category!(owner, group, %{type: :topic, name: "Older corner"})

      assert {:ok, _} =
               Bonfire.Classify.Categories.add_member(owner, group, id(member),
                 skip_boundary_check: true
               )

      {:ok, circle} = Bonfire.Classify.Categories.members_circle(group)
      {:ok, acl} = Bonfire.Boundaries.Acls.get_object_custom_acl(topic)
      Bonfire.Boundaries.Grants.grant(circle, acl, [:follow], nil, current_user: owner)

      assert {:error, :not_permitted} = Follows.follow(member, topic),
             "control: without the grant, as before"

      Bonfire.Classify.TopicMembersFollow.DataMigration.base_query()
      |> Bonfire.Common.Repo.all()
      |> Bonfire.Classify.TopicMembersFollow.DataMigration.migrate()

      assert {:ok, %Bonfire.Data.Social.Follow{}} = Follows.follow(member, topic)
    end

    # the button passes the id when it has no object in its assigns
    test "following a topic by its id follows it", %{topic: topic} do
      other = Fake.fake_user!()
      assert {:ok, %Bonfire.Data.Social.Follow{}} = Follows.follow(other, id(topic))
    end
  end
end
