if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Classify.API.GraphQL.UserGroupsTest do
    @moduledoc """
    A user's followed groups, listed through `me { user { groups } }` and `Bonfire.Classify.my_followed_tree/2`, contain only groups that still exist. A follow of an archived group persists, so without that guarantee the list carries an entry with no group behind it, and the `character`/`profile` fields (resolved by Dataloader, which needs an Ecto struct) crash the whole query.
    """
    use Bonfire.Classify.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema
    alias Bonfire.Classify.Categories
    alias Bonfire.Classify.Category
    alias Bonfire.Classify.Simulate
    alias Bonfire.Me.Fake
    alias Bonfire.Social.Graph.Follows

    @moduletag :graphql

    @my_groups """
    query {
      me {
        user {
          groups {
            edges {
              id
              character { username }
              profile { name }
            }
          }
        }
      }
    }
    """

    defp open_group!(creator) do
      Simulate.fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })
    end

    setup do
      Process.put(:federating, false)

      creator = Fake.fake_user!()
      me = Fake.fake_user!()
      kept = open_group!(creator)
      archived = open_group!(creator)

      for group <- [kept, archived] do
        assert {:ok, _} = Follows.follow(me, group, skip_boundary_check: true)
      end

      assert {:ok, _} = Categories.soft_delete(archived, creator)

      {:ok, me: me, creator: creator, kept: kept, archived: archived}
    end

    test "me.user.groups resolves character and profile of a group for its creator",
         %{creator: creator, kept: kept} do
      if not Follows.following?(creator, kept) do
        assert {:ok, _} = Follows.follow(creator, kept, skip_boundary_check: true)
      end

      {:ok, result} =
        Absinthe.run(@my_groups, Schema, context: Schema.context(%{current_user: creator}))

      refute result[:errors]

      groups = get_in(result, [:data, "me", "user", "groups", "edges"])
      group = Enum.find(groups, &(&1["id"] == kept.id))

      assert group, "control: the creator's followed group is listed, got: #{inspect(groups)}"

      assert is_binary(get_in(group, ["character", "username"])),
             "expected the group's character with a username, got: #{inspect(group)}"

      assert is_binary(get_in(group, ["profile", "name"])),
             "expected the group's profile with a name, got: #{inspect(group)}"
    end

    test "me.user.groups resolves character and profile of followed groups, leaving out archived ones",
         %{me: me, kept: kept, archived: archived} do
      {:ok, result} =
        Absinthe.run(@my_groups, Schema, context: Schema.context(%{current_user: me}))

      refute result[:errors]

      groups = get_in(result, [:data, "me", "user", "groups", "edges"])
      ids = Enum.map(groups, & &1["id"])

      assert kept.id in ids, "control: the group that still exists is listed"
      refute archived.id in ids

      group = Enum.find(groups, &(&1["id"] == kept.id))

      assert is_binary(get_in(group, ["character", "username"])),
             "expected the group's character with a username, got: #{inspect(group)}"

      assert is_binary(get_in(group, ["profile", "name"])),
             "expected the group's profile with a name, got: #{inspect(group)}"
    end

    test "my_followed_tree lists only existing groups", %{me: me, kept: kept, archived: archived} do
      {tree, _page_info} = Bonfire.Classify.my_followed_tree(me, [])
      groups = Enum.map(tree, fn {group, _children} -> group end)

      assert Enum.any?(groups, &(&1.id == kept.id)),
             "control: the group that still exists is listed"

      for group <- groups do
        assert is_struct(group, Category), "expected a %Category{}, got: #{inspect(group)}"
      end

      refute Enum.any?(groups, &(Map.get(&1, :id) == archived.id))
    end
  end
end
