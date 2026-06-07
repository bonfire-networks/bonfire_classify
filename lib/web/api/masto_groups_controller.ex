if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Classify.Web.API.GroupsController do
    @moduledoc "Mastodon-compatible Groups REST endpoints."

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Classify.API.Masto.GroupsAdapter

    def index(conn, params), do: GroupsAdapter.list_groups(params, conn)
    def show(conn, %{"id" => id}), do: GroupsAdapter.get_group(id, conn)
    def create(conn, params), do: GroupsAdapter.create_group(params, conn)
    def update(conn, %{"id" => id} = params), do: GroupsAdapter.update_group(id, params, conn)
    def join(conn, %{"id" => id}), do: GroupsAdapter.join_group(id, conn)
    def leave(conn, %{"id" => id}), do: GroupsAdapter.leave_group(id, conn)

    def list_members(conn, %{"id" => id} = params),
      do: GroupsAdapter.list_members(id, params, conn)

    def add_member(conn, %{"id" => id, "request_id" => req_id}),
      do: GroupsAdapter.accept_join_request(id, req_id, conn)

    def add_member(conn, %{"id" => id, "account_id" => account_id}),
      do: GroupsAdapter.add_member(id, account_id, conn)

    def remove_member(conn, %{"id" => id, "account_id" => account_id}),
      do: GroupsAdapter.remove_member(id, account_id, conn)
  end
end
