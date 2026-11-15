defmodule Bonfire.Classify.ConvertGroupTopicTest do
  @moduledoc """
  One of our categories converted from a topic into a group, or back (`Categories.convert/3`), by whoever may edit its settings. A topic in a group becomes a SUBGROUP: it keeps its parent, gets a group's circles, and its parent's dimensions. A group becoming a topic keeps its circles, so converting back finds them. (How the instances that mirror it hear of it is in `dance/group_or_topic_dance_test.exs`.)
  """
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils
  @moduletag :backend

  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Simulate
  import Bonfire.Me.Fake, only: [fake_user!: 0]

  setup do
    creator = fake_user!()

    group =
      Simulate.fake_group!(creator, %{
        membership: "on_request",
        visibility: "global",
        participation: "group_members"
      })

    topic = Simulate.fake_category!(creator, group, %{type: :topic})

    {:ok, creator: creator, group: group, topic: topic}
  end

  test "someone who may not edit it can't convert it", %{creator: creator, topic: topic} do
    assert {:error, _} = Categories.convert(topic, :group, current_user: fake_user!())
    assert {:ok, %{type: :topic}} = Categories.get(id(topic), skip_boundary_check: true)

    assert {:ok, %{type: :group}} = Categories.convert(topic, :group, current_user: creator),
           "control: its creator may"
  end

  test "a topic in a group becomes a subgroup, with its parent's dimensions and circles of its own",
       %{creator: creator, group: group, topic: topic} do
    assert topic.type == :topic, "control: a topic to begin with"

    assert {:ok, subgroup} = Categories.convert(topic, :group, current_user: creator)
    subgroup = Bonfire.Common.Repo.maybe_preload(subgroup, :tree)

    assert subgroup.tree.parent_id == id(group), "it stays in its group"
    assert {:ok, _} = Categories.members_circle(subgroup), "a membership of its own"

    parent_dims = Bonfire.Boundaries.Presets.group_dimension_slugs(group)
    dims = Bonfire.Boundaries.Presets.group_dimension_slugs(subgroup)

    assert dims[:membership] == parent_dims[:membership]
    assert dims[:participation] == parent_dims[:participation]
  end

  test "a moderator, who holds no :configure, converts it and its group rules are written",
       %{creator: creator, group: group, topic: topic} do
    mod = fake_user!()
    {:ok, _} = Categories.add_moderator(creator, group, id(mod))
    # moderating the topic itself, as the group's moderators circle does for the group
    Bonfire.Boundaries.Controlleds.grant_role(id(mod), topic, :moderate,
      skip_boundary_check: true
    )

    assert Bonfire.Boundaries.can?(mod, :mediate, topic), "control: they moderate it"
    refute Bonfire.Boundaries.can?(mod, :configure, topic), "control: but may not configure it"
    refute Bonfire.Boundaries.can?(mod, :configure, group)

    assert {:ok, %{type: :group} = subgroup} =
             Categories.convert(topic, :group, current_user: mod)

    parent_dims = Bonfire.Boundaries.Presets.group_dimension_slugs(group)
    dims = Bonfire.Boundaries.Presets.group_dimension_slugs(subgroup)

    assert parent_dims[:membership] == "on_request",
           "control: the parent's rules are not the default"

    assert dims[:membership] == parent_dims[:membership]
    assert dims[:visibility] == parent_dims[:visibility]
    assert dims[:participation] == parent_dims[:participation]
  end

  test "a non-moderator can't convert it, and it stays a topic", %{
    creator: creator,
    group: group,
    topic: topic
  } do
    member = fake_user!()
    {:ok, _} = Categories.join_and_follow_group(member, group, skip_boundary_check: true)

    assert {:error, _} = Categories.convert(topic, :group, current_user: member)
    assert {:ok, %{type: :topic}} = Categories.get(id(topic), skip_boundary_check: true)
    assert {:ok, %{type: :group}} = Categories.convert(topic, :group, current_user: creator)
  end

  test "a group becoming a topic keeps its circles", %{creator: creator, group: group} do
    assert {:ok, circle} = Categories.members_circle(group)

    assert {:ok, %{type: :topic} = topic} =
             Categories.convert(group, :topic, current_user: creator)

    assert {:ok, kept} = Categories.members_circle(topic)
    assert id(kept) == id(circle)
  end
end
