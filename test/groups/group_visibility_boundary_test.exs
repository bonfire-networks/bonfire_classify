if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupVisibilityBoundaryTest do
    @moduledoc """
    Who may see and read a group is answered by its VISIBILITY dimension, at creation.

    A group states its dimensions as slugs, the way a post states `"public"` or `"mentions"`, and each slug names the ACLs it applies. Several of them name none at all (eg. `invite_only` membership, `members:private` visibility, `group_members` participation) because those groups are reached through the members circle rather than through a global grant. Naming no ACLs has to survive the trip to the grant machinery as "this group grants nothing globally", distinct from a group that stated no preference and takes the instance default.

    So the case worth pinning is the one where every dimension names nothing: a stranger gets neither verb, while a group that does name a public visibility gives them both.
    """
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils

    alias Bonfire.Classify.Categories
    alias Bonfire.Boundaries
    alias Bonfire.Me.Fake

    setup do
      # nothing here federates; publishing/boundary changes otherwise spawn federation tasks with no DB ownership in tests
      Process.put(:federating, false)

      :ok
    end

    defp create_group_with(creator, dims) do
      {:ok, group} =
        Categories.create(
          creator,
          Enum.into(dims, %{
            type: :group,
            name: "Test Group #{System.unique_integer([:positive])}"
          }),
          true
        )

      group
    end

    test "a group whose dimensions all name no ACLs grants a stranger neither :see nor :read" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()

      group =
        create_group_with(creator,
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members"
        )

      refute Boundaries.can?(stranger, :read, group)
      refute Boundaries.can?(stranger, :see, group)

      # the creator still reaches their own group, so "nobody can read it" is not how it passes
      assert Boundaries.can?(creator, :read, group)
    end

    test "a group whose visibility names a public one grants a stranger both" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()

      group =
        create_group_with(creator,
          membership: "open",
          visibility: "global",
          participation: "anyone"
        )

      assert Boundaries.can?(stranger, :read, group)
      assert Boundaries.can?(stranger, :see, group)
    end
  end
end
