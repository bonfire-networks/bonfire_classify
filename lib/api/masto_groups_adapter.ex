if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Classify.API.Masto.GroupsAdapter do
    @moduledoc "Mastodon-compatible Groups API adapter using GraphQL internal mode."

    use AbsintheClient,
      schema: Bonfire.API.GraphQL.Schema,
      action: [mode: :internal]

    use Arrows
    import Untangle
    alias Bonfire.API.GraphQL.RestAdapter

    @group_fields """
      id
      display_name: name
      type
      members_count
      is_disabled
      parent_group_id: parent_category_id
      boundaries { key slug }
      character { username }
    """

    @rel_fields "member role following requested"

    @member_fields """
      entries {
        account { id profile { name } character { username } }
        relationship { #{@rel_fields} }
      }
    """

    @graphql "query { categories { edges { #{@group_fields} } } }"
    def list_groups(params, conn) do
      graphql(conn, :list_groups, %{})
      |> RestAdapter.return(
        :categories,
        ...,
        conn,
        fn %{edges: groups} ->
          groups
          |> maybe_filter_type(params["type"])
          |> Enum.map(&wrap_group/1)
        end,
        filter_nils: false
      )
    end

    @graphql "query($id: ID!) { category(category_id: $id) { #{@group_fields} } }"
    def get_group(id, conn) do
      graphql(conn, :get_group, %{"id" => id})
      |> RestAdapter.return(:category, ..., conn, &wrap_group/1, filter_nils: false)
    end

    @graphql """
    mutation($name: String!, $type: String, $preset: String) {
      create_category(category: {name: $name, type: $type, boundary: {preset: $preset}}) {
        #{@group_fields}
      }
    }
    """
    def create_group(params, conn) do
      vars = %{
        "name" => params["name"],
        "type" => params["type"] || "group",
        "preset" => get_in(params, ["boundary", "preset"])
      }

      graphql(conn, :create_group, vars)
      |> RestAdapter.return(:create_category, ..., conn, &wrap_group/1, filter_nils: false)
    end

    @graphql """
    mutation($id: ID!, $name: String, $preset: String) {
      update_category(category_id: $id, category: {name: $name, boundary: {preset: $preset}}) {
        #{@group_fields}
      }
    }
    """
    def update_group(id, params, conn) do
      vars = %{
        "id" => id,
        "name" => params["name"],
        "preset" => get_in(params, ["boundary", "preset"])
      }

      graphql(conn, :update_group, vars)
      |> RestAdapter.return(:update_category, ..., conn, &wrap_group/1, filter_nils: false)
    end

    @graphql "mutation($id: ID!) { join_group(group_id: $id) { #{@rel_fields} } }"
    def join_group(id, conn) do
      graphql(conn, :join_group, %{"id" => id})
      |> RestAdapter.return(:join_group, ..., conn, &wrap_rel(id, &1))
    end

    @graphql "mutation($id: ID!) { leave_group(group_id: $id) { #{@rel_fields} } }"
    def leave_group(id, conn) do
      graphql(conn, :leave_group, %{"id" => id})
      |> RestAdapter.return(:leave_group, ..., conn, &wrap_rel(id, &1))
    end

    @graphql """
    query($id: ID!, $role: String) {
      category(category_id: $id) {
        members(role: $role) { #{@member_fields} }
      }
    }
    """
    def list_members(id, params, conn) do
      graphql(conn, :list_members, %{"id" => id, "role" => params["role"]})
      |> RestAdapter.return(:category, ..., conn, fn %{members: %{entries: entries}} ->
        Enum.map(entries, &wrap_member/1)
      end)
    end

    @graphql "mutation($gid: ID!, $uid: ID!) { add_member(group_id: $gid, account_id: $uid) { #{@rel_fields} } }"
    def add_member(group_id, account_id, conn) do
      graphql(conn, :add_member, %{"gid" => group_id, "uid" => account_id})
      |> RestAdapter.return(:add_member, ..., conn, &wrap_rel(group_id, &1))
    end

    @graphql "mutation($req: ID!) { accept_join_request(request_id: $req) { #{@rel_fields} } }"
    def accept_join_request(group_id, request_id, conn) do
      graphql(conn, :accept_join_request, %{"req" => request_id})
      |> RestAdapter.return(:accept_join_request, ..., conn, &wrap_rel(group_id, &1))
    end

    @graphql "mutation($gid: ID!, $uid: ID!) { remove_member(group_id: $gid, account_id: $uid) }"
    def remove_member(group_id, account_id, conn) do
      graphql(conn, :remove_member, %{"gid" => group_id, "uid" => account_id})
      |> RestAdapter.return(:remove_member, ..., conn)
    end

    # --- minimal post-processing ---

    defp wrap_group(group) do
      membership_slug =
        (group[:boundaries] || [])
        |> Enum.find_value(&if(to_string(&1[:key]) == "membership", do: &1[:slug]))

      group
      |> Map.put(:group, Map.put(group, :join_mode, membership_to_join_mode(membership_slug)))
    end

    defp wrap_rel(group_id, rel) do
      %{
        id: group_id,
        following: rel[:following],
        requested: rel[:requested],
        group: %{member: rel[:member], role: rel[:role]}
      }
    end

    defp wrap_member(entry) do
      account = entry[:account] || %{}
      rel = entry[:relationship] || %{}

      %{
        account: %{
          id: account[:id],
          display_name: get_in(account, [:profile, :name]),
          username: get_in(account, [:character, :username])
        },
        relationship: %{
          id: account[:id],
          group: %{member: rel[:member], role: rel[:role]}
        }
      }
    end

    defp maybe_filter_type(groups, nil), do: groups
    defp maybe_filter_type(groups, type), do: Enum.filter(groups, &(to_string(&1[:type]) == type))

    defp membership_to_join_mode("open"), do: "free"
    defp membership_to_join_mode("local:members"), do: "free"
    defp membership_to_join_mode("on_request"), do: "request"
    defp membership_to_join_mode("invite_only"), do: "invite"
    defp membership_to_join_mode(_), do: "free"
  end
end
