defmodule Bonfire.Classify.Web.TopicsSubheaderLive do
  use Bonfire.UI.Common.Web, :stateful_component

  def update(assigns, socket) do
    params = e(assigns, :__context__, :current_params, %{})
    limit = Bonfire.Common.Config.get(:default_pagination_limit, 10)

    {:ok, categories} =
      Bonfire.Classify.GraphQL.CategoryResolver.categories_toplevel(
        %{limit: limit},
        %{context: %{current_user: current_user(socket.assigns)}}
      )

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       categories: e(categories, :edges, []),
       limit: limit
     )}
  end

  def category_link(category) do
    id = e(category, :character, :username, nil) || e(category, :id, "#no-parent")

    "/+" <> id
  end

  def handle_event(
        action,
        attrs,
        socket
      ),
      do:
        Bonfire.UI.Common.LiveHandlers.handle_event(
          action,
          attrs,
          socket,
          __MODULE__
          # &do_handle_event/3
        )
end
