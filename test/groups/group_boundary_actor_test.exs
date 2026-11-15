defmodule Bonfire.Classify.GroupBoundaryActorTest do
  @moduledoc """
  Who a group's boundary writes are made as. A person writes as themselves, and so is checked. Only a mirror of a remote group (whose subject is the group, or its parent group) and the backfills write with no person acting. A missing subject, or a bare id, is never read as "system", and someone leaving a group is only ever removed as themselves.
  """
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils
  @moduletag :backend

  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Boundaries, as: ClassifyBoundaries
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

    {:ok, creator: creator, group: group}
  end

  describe "init_boundaries/4" do
    test "with no creator, nothing is written", %{group: group} do
      dims = Bonfire.Boundaries.Presets.group_dimension_slugs(group)
      assert dims[:membership] == "on_request", "control: not the default"

      assert {:error, _} =
               ClassifyBoundaries.init_boundaries(:group, group, nil, %{
                 membership: "open",
                 visibility: "local:unlisted",
                 participation: "group_members"
               })

      assert Bonfire.Boundaries.Presets.group_dimension_slugs(group) == dims
    end

    test "with the bare id of someone who may not configure it as the subject, nothing is written",
         %{group: group} do
      assert {:error, _} =
               ClassifyBoundaries.init_boundaries(:group, group, id(fake_user!()), %{
                 membership: "open",
                 visibility: "local:unlisted",
                 participation: "group_members"
               })
    end

    test "a person who may configure the group writes it", %{creator: creator, group: group} do
      assert {:ok, _} =
               ClassifyBoundaries.init_boundaries(:group, group, creator, %{
                 membership: "open",
                 visibility: "global",
                 participation: "group_members"
               })

      assert Bonfire.Boundaries.Presets.group_dimension_slugs(group)[:membership] == "open"
    end

    test "a mirror, whose subject is the group itself, writes with no person", %{group: group} do
      assert {:ok, _} =
               ClassifyBoundaries.init_boundaries(:group, group, group, %{
                 membership: "open",
                 visibility: "global",
                 participation: "group_members"
               })

      assert Bonfire.Boundaries.Presets.group_dimension_slugs(group)[:membership] == "open"
    end
  end

  describe "leave_group/3" do
    setup %{group: group} do
      member = fake_user!()
      {:ok, _} = Categories.join_and_follow_group(member, group, skip_boundary_check: true)
      {:ok, circle} = Categories.members_circle(group)
      assert Bonfire.Boundaries.Circles.is_encircled_by?(member, circle), "control: a member"
      {:ok, member: member, circle: circle}
    end

    test "someone else acting for the member can't remove them", %{
      group: group,
      member: member,
      circle: circle
    } do
      attacker = fake_user!()

      assert {:error, _} = Categories.leave_group(member, group, current_user: attacker)
      assert Bonfire.Boundaries.Circles.is_encircled_by?(member, circle)
    end

    test "a member leaves as themselves", %{group: group, member: member, circle: circle} do
      assert {:ok, %{member: false}} = Categories.leave_group(member, group, current_user: member)
      refute Bonfire.Boundaries.Circles.is_encircled_by?(member, circle)
    end
  end
end
