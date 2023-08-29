defmodule Bonfire.Classify.Web.TopicsNavLive do
  use Bonfire.UI.Common.Web, :stateful_component

  def update(assigns, socket) do
    params = e(assigns, :__context__, :current_params, %{})

    followed =
      Bonfire.Social.Follows.list_my_followed(
        current_user(assigns) || current_user(socket.assigns),
        pagination: %{limit: 500},
        type: Bonfire.Classify.Category
      )

    followed_categories =
      followed
      |> e(:edges, [])
      |> Enum.map(&e(&1, :edge, :object, nil))

    {:ok,
     socket
     |> assign(assigns)
     |> assign(topics: followed_categories)}
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
