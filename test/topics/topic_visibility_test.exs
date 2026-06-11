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

    test "a top-level topic (no parent group) is public" do
      creator = Fake.fake_user!()
      other = Fake.fake_user!()

      topic = fake_category!(creator, nil, %{type: :topic, name: "Standalone"})

      assert Boundaries.can?(creator, :read, topic)
      assert Boundaries.can?(other, :read, topic)
    end
  end
end
