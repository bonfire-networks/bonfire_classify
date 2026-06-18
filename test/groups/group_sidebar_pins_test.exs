if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupSidebarPinsTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Me.Fake
    alias Bonfire.Classify.Categories
    alias Bonfire.Social.Pins

    setup do
      # TEMP: until we work on group federation
      Process.put(:federating, false)
      :ok
    end

    # ids of every group in the user's pin-driven sidebar tree
    defp sidebar_ids(user) do
      flatten_ids(Bonfire.Classify.my_pinned_tree(user))
    end

    defp flatten_ids(tree) do
      Enum.flat_map(tree, fn {category, children} ->
        [id(category) | flatten_ids(children)]
      end)
    end

    test "creating a group pins it to the creator's sidebar" do
      creator = Fake.fake_user!()
      group = fake_group!(creator)

      assert Pins.pinned?(creator, group)
      assert id(group) in sidebar_ids(creator)
    end

    test "joining an open group auto-pins it to the member's sidebar" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()
      group = fake_group!(creator, %{membership: "local:members"})

      refute id(group) in sidebar_ids(member)

      {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)

      assert Pins.pinned?(member, group)
      assert id(group) in sidebar_ids(member)
    end

    test "leaving a group unpins it from the sidebar" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()
      group = fake_group!(creator, %{membership: "local:members"})

      {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)
      assert id(group) in sidebar_ids(member)

      {:ok, _} = Categories.leave_group(member, group)

      refute Pins.pinned?(member, group)
      refute id(group) in sidebar_ids(member)
    end

    test "unpinning hides the group from the sidebar but keeps membership" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()
      group = fake_group!(creator, %{membership: "local:members"})

      {:ok, _} = Categories.join_group(member, group, skip_boundary_check: true)
      assert id(group) in sidebar_ids(member)

      Pins.unpin(member, group)

      refute id(group) in sidebar_ids(member)
      # unpin only affects the sidebar — the user is still a member
      assert Categories.member?(member, group)
    end

    test "archiving a group removes it from the sidebar; unarchiving restores it" do
      creator = Fake.fake_user!()
      group = fake_group!(creator)

      # created → auto-pinned → in sidebar
      assert id(group) in sidebar_ids(creator)

      {:ok, _} = Categories.soft_delete(group, creator)
      # archived (soft-deleted) groups must not linger in the sidebar even though the pin persists
      refute id(group) in sidebar_ids(creator)

      {:ok, _} = Categories.unarchive(id(group), creator)
      assert id(group) in sidebar_ids(creator)
    end

    test "an archived instance-pinned group does not appear in anyone's sidebar" do
      creator = Fake.fake_user!()
      other = Fake.fake_user!()
      group = fake_group!(creator, %{membership: "local:members"})

      {:ok, _} =
        Pins.pin(Pins.instance_scope_id(), group, nil, skip_boundary_check: true, to_feeds: [])

      assert id(group) in sidebar_ids(other)

      {:ok, _} = Categories.soft_delete(group, creator)
      refute id(group) in sidebar_ids(other)
    end

    test "admins can set the order of instance-pinned groups in everyone's sidebar" do
      creator = Fake.fake_user!()
      other = Fake.fake_user!()
      group_a = fake_group!(creator, %{membership: "local:members"})
      group_b = fake_group!(creator, %{membership: "local:members"})

      for g <- [group_a, group_b] do
        {:ok, _} =
          Pins.pin(Pins.instance_scope_id(), g, nil, skip_boundary_check: true, to_feeds: [])
      end

      # rank B before A
      {:ok, _} = Pins.rank_pin(id(group_b), :instance, 0)
      {:ok, _} = Pins.rank_pin(id(group_a), :instance, 1)

      assert [id(group_b), id(group_a)] == Enum.take(sidebar_ids(other), 2)

      # RE-rank an already-ranked group (this path previously crashed) → A moves to the front
      {:ok, _} = Pins.rank_pin(id(group_a), :instance, 0)
      assert [id(group_a), id(group_b)] == Enum.take(sidebar_ids(other), 2)
    end

    test "reordering instance pins is correct across a sequence of moves" do
      creator = Fake.fake_user!()
      other = Fake.fake_user!()
      a = fake_group!(creator, %{membership: "local:members"})
      b = fake_group!(creator, %{membership: "local:members"})
      c = fake_group!(creator, %{membership: "local:members"})

      for g <- [a, b, c] do
        {:ok, _} =
          Pins.pin(Pins.instance_scope_id(), g, nil, skip_boundary_check: true, to_feeds: [])
      end

      order = fn -> Enum.take(sidebar_ids(other), 3) end

      # establish A, B, C
      for {g, i} <- Enum.with_index([a, b, c]), do: {:ok, _} = Pins.rank_pin(id(g), :instance, i)
      assert [id(a), id(b), id(c)] == order.()

      # move C to the front
      {:ok, _} = Pins.rank_pin(id(c), :instance, 0)
      assert [id(c), id(a), id(b)] == order.()

      # move C to the middle
      {:ok, _} = Pins.rank_pin(id(c), :instance, 1)
      assert [id(a), id(c), id(b)] == order.()

      # move A to the end
      {:ok, _} = Pins.rank_pin(id(a), :instance, 2)
      assert [id(c), id(b), id(a)] == order.()
    end

    test "an instance pin can be removed by binary id (the path the settings toggle uses)" do
      creator = Fake.fake_user!()
      group = fake_group!(creator, %{visibility: "members:private"})

      {:ok, _} =
        Pins.pin(Pins.instance_scope_id(), group, nil, skip_boundary_check: true, to_feeds: [])

      assert Pins.pinned?(:instance, group)

      # reach the binary-id unpin clause directly (as `Pins.unpin(admin, id, :instance)` does after
      # its `:mediate` check) — previously the boundarised reload failed for a non-public group
      Pins.unpin(Pins.instance_scope_id(), id(group), nil)

      refute Pins.pinned?(:instance, group)
    end

    test "an instance-pinned group appears in another user's sidebar" do
      creator = Fake.fake_user!()
      other = Fake.fake_user!()
      group = fake_group!(creator, %{membership: "local:members"})

      refute id(group) in sidebar_ids(other)

      # simulate an admin instance-pin (subject = the instance scope)
      {:ok, _} =
        Pins.pin(Pins.instance_scope_id(), group, nil, skip_boundary_check: true, to_feeds: [])

      assert id(group) in sidebar_ids(other)
    end
  end
end
