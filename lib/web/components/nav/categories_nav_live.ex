defmodule Bonfire.Classify.Web.CategoriesNavLive do
  use Bonfire.UI.Common.Web, :stateful_component

  def update(assigns, socket) do
    params = e(assigns, :__context__, :current_params, %{})
    topics = Bonfire.Social.Follows.list_my_followed(current_user(assigns), pagination: false, type: Bonfire.Classify.Category)  |> IO.inspect(label: "TESTTTT")

    {:ok, socket
      |> assign(assigns)
      |> assign(
        topics: e(topics, :edges, [])
      )
    }
  end

  def category_link(category) do
    id = e(category, :character, :username, nil) || e(category, :id, "#no-parent")

    "/+" <> id
  end
end
