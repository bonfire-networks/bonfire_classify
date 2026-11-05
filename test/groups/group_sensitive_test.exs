if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupSensitiveTest do
    @moduledoc """
    A group or topic marked sensitive (a content warning on the whole group), stored in the same `Sensitive` mixin as a post's mark, so it means the same thing in the same place.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Classify.Categories
    alias Bonfire.Social.Objects

    defp reload(category) do
      {:ok, got} = Categories.get(id(category), [:default, skip_boundary_check: true])
      got
    end

    setup do
      creator = Bonfire.Me.Fake.fake_user!()
      group = fake_group!(creator)
      {:ok, creator: creator, group: group}
    end

    test "a group marked sensitive reads back as marked, and unmarked as not", %{group: group} do
      assert {:ok, _} = Objects.set_sensitivity(group, true)
      got = reload(group)
      assert Categories.sensitive?(got) == true

      assert {:ok, _} = Objects.set_sensitivity(got, false)
      assert Categories.sensitive?(reload(group)) == false
    end

    test "a group's moderator marks it sensitive, and someone who is not cannot", %{
      creator: creator,
      group: group
    } do
      assert {:ok, _} = Categories.update(creator, group, %{sensitive: true})
      got = reload(group)
      assert Categories.sensitive?(got) == true

      other = Bonfire.Me.Fake.fake_user!()
      refute match?({:ok, _}, Categories.update(other, got, %{sensitive: false}))
      assert Categories.sensitive?(reload(group)) == true
    end

    test "a group's moderator unmarks it", %{creator: creator, group: group} do
      assert {:ok, _} = Categories.update(creator, group, %{sensitive: true})
      assert {:ok, _} = Categories.update(creator, reload(group), %{sensitive: false})
      assert Categories.sensitive?(reload(group)) == false
    end

    test "a group created with `sensitive: true` starts marked, and without it unmarked", %{
      creator: creator
    } do
      marked = Bonfire.Classify.Simulate.fake_group!(creator, %{sensitive: "true"})
      assert Categories.sensitive?(reload(marked)) == true

      assert Categories.sensitive?(reload(fake_group!(creator))) == false
    end

    # each topic has its own mark, which starts as its group's when the topic is made, and is its own after that
    describe "topics" do
      defp topic!(creator, group, attrs \\ %{}) do
        Bonfire.Classify.Simulate.fake_category!(
          creator,
          group,
          Map.merge(%{type: :topic, name: "topic #{System.unique_integer([:positive])}"}, attrs)
        )
      end

      defp marked_group!(creator) do
        group = fake_group!(creator)
        assert {:ok, _} = Objects.set_sensitivity(group, true)
        reload(group)
      end

      test "a topic made in a group not marked sensitive starts unmarked", %{
        creator: creator,
        group: group
      } do
        assert Categories.sensitive?(reload(topic!(creator, group))) == false
      end

      test "a topic made in a group marked sensitive starts marked", %{creator: creator} do
        topic = topic!(creator, marked_group!(creator))
        assert Categories.sensitive?(reload(topic)) == true
      end

      test "a topic made with `sensitive: false` in a group marked sensitive starts unmarked", %{
        creator: creator
      } do
        topic = topic!(creator, marked_group!(creator), %{sensitive: false})
        assert Categories.sensitive?(reload(topic)) == false
      end

      test "turning a topic's mark off sticks", %{creator: creator} do
        group = marked_group!(creator)
        topic = topic!(creator, group)
        assert Categories.sensitive?(reload(topic)) == true, "control: started marked"

        assert {:ok, _} = Categories.update(creator, reload(topic), %{sensitive: false})
        assert Categories.sensitive?(reload(topic)) == false

        assert {:ok, _} = Categories.update(creator, group, %{profile: %{summary: "edited"}})
        assert Categories.sensitive?(reload(topic)) == false
      end

      test "changing the group's mark later leaves its topics as they are", %{
        creator: creator,
        group: unmarked
      } do
        marked = marked_group!(creator)
        marked_topic = topic!(creator, marked)
        assert {:ok, _} = Categories.update(creator, marked, %{sensitive: false})
        assert Categories.sensitive?(reload(marked_topic)) == true

        unmarked_topic = topic!(creator, unmarked)
        assert {:ok, _} = Categories.update(creator, unmarked, %{sensitive: true})
        assert Categories.sensitive?(reload(unmarked_topic)) == false
      end
    end
  end
end
