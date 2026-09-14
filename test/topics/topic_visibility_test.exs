if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.TopicVisibilityTest do
    @moduledoc """
    Regression coverage for the bug where a topic created inside a group was only
    visible to its creator: `init_boundaries` for non-group categories used to
    grant the creator `:administer` and nothing else, so the topic inherited no
    read boundary. Topics now inherit the parent group's audience (and top-level
    topics default to public).
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Me.Fake
    alias Bonfire.Boundaries

    setup do
      Process.put(:federating, false)
      :ok
    end

    test "a topic in a PUBLIC group is readable by other users" do
      creator = Fake.fake_user!()
      other = Fake.fake_user!()

      group = fake_group!(creator, %{name: "Public Group", visibility: "global"})
      topic = fake_category!(creator, group, %{type: :topic, name: "Planning"})

      assert Boundaries.can?(creator, :read, topic)
      assert Boundaries.can?(other, :read, topic)
    end

    test "a topic in a MEMBERS-ONLY group is readable by members but not outsiders" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()
      outsider = Fake.fake_user!()

      group =
        fake_group!(creator, %{name: "Private Group", visibility: "members:private"})

      {:ok, _} = Bonfire.Classify.Categories.add_member(creator, group, id(member))

      topic = fake_category!(creator, group, %{type: :topic, name: "Secret Plans"})

      assert Boundaries.can?(creator, :read, topic)
      assert Boundaries.can?(member, :read, topic), "a group member should read the topic"

      refute Boundaries.can?(outsider, :read, topic),
             "a non-member should NOT read a topic in a members-only group"
    end

    test "batch previews include direct topics of nested groups and exclude deeper descendants" do
      creator = Fake.fake_user!()
      root = fake_group!(creator)
      nested = fake_category!(creator, root, %{type: :group, name: Faker.Lorem.word()})
      topic = fake_category!(creator, nested, %{type: :topic, name: Faker.Lorem.word()})
      _descendant = fake_category!(creator, topic, %{type: :topic, name: Faker.Lorem.word()})

      previews =
        Bonfire.Classify.Categories.list_topics_for_groups([root, nested], current_user: creator)

      assert Enum.map(previews[nested.id], & &1.id) == [topic.id]
      refute Map.has_key?(previews, root.id)
    end

    # A topic is an actor with its own character, so it is blockable like any other. Silencing one adds the silencer to the TOPIC's own `silence_me` circle, and `cannot_discover_if_silenced` is what turns that into a refusal. It arrives with `:object_default_boundaries`, which only get attached when the topic's visibility slug is actually applied, so a topic whose parent group names no global ACLs is the case to pin.
    test "a member can silence a topic in a members-only group" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()

      group =
        fake_group!(creator, %{name: "Private Group", visibility: "members:private"})

      {:ok, _} = Bonfire.Classify.Categories.add_member(creator, group, id(member))

      topic = fake_category!(creator, group, %{type: :topic, name: "Noisy Thread"})

      assert Boundaries.can?(member, :see, topic),
             "the control: the member can see it before silencing, so the refusal below is the block rather than the fixture"

      assert {:ok, _} = Bonfire.Boundaries.Blocks.block(topic, :silence, current_user: member)

      refute Boundaries.can?(member, :see, topic),
             "silencing a topic has to actually hide it, which needs the per-object ACL that carries the denial"
    end

    test "a top-level topic (no parent group) is public" do
      creator = Fake.fake_user!()
      other = Fake.fake_user!()

      topic = fake_category!(creator, nil, %{type: :topic, name: "Standalone"})

      assert Boundaries.can?(creator, :read, topic)
      assert Boundaries.can?(other, :read, topic)
    end
  end
end
