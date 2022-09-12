defmodule Bonfire.Classify.Web.CategoriesNavLive do
  use Bonfire.UI.Common.Web, :stateful_component

  declare_widget("Links to followed topics")

  def update(assigns, socket) do
    params = e(assigns, :__context__, :current_params, %{})

    # TODO: configurable
    limit = 5

    # |> debug("TESTTTT")
    topics =
      Bonfire.Social.Follows.list_my_followed(current_user(assigns),
        limit: limit,
        type: Bonfire.Classify.Category
      )

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       topics: e(topics, :edges, []),
       limit: limit
     )}
  end

  def category_link(category) do
    id = e(category, :character, :username, nil) || e(category, :id, "#no-parent")

    "/+" <> id
  end
end
