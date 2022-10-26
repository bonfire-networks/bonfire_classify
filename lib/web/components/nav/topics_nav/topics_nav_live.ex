defmodule Bonfire.Classify.Web.TopicsNavLive do
  use Bonfire.UI.Common.Web, :stateful_component

  def update(assigns, socket) do
    params = e(assigns, :__context__, :current_params, %{})

    # TODO: configurable

    # |> debug("TESTTTT")
    topics =
      Bonfire.Social.Follows.list_my_followed(current_user(assigns),
        type: Bonfire.Classify.Category
      )

    {:ok,
     socket
     |> assign(assigns)
     |> assign(topics: e(topics, :edges, []))}
  end

  def category_link(category) do
    id = e(category, :character, :username, nil) || e(category, :id, "#no-parent")

    "/+" <> id
  end
end
