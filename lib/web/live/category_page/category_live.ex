defmodule Bonfire.Classify.Web.Page.Category do
  use Bonfire.Web, :live_view

  alias Bonfire.Classify.Web.Page.Category.SubcategoriesLive
  alias Bonfire.Classify.Web.CommunityLive.CommunityCollectionsLive
  alias Bonfire.Classify.Web.CollectionLive.CollectionResourcesLive

  alias Bonfire.Web.LivePlugs

  def mount(params, session, socket) do
    LivePlugs.live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf, LivePlugs.Locale,
      &mounted/3
    ]
  end

  defp mounted(params, _session, socket) do
    # socket = init_assigns(params, session, socket)

    {:ok,
     socket
     |> assign(
     page: 1,
     category: %{},
     object_type: nil
     )}
  end

  def handle_params(%{} = params, _url, socket) do

    top_level_category = System.get_env("TOP_LEVEL_CATEGORY", "")

    id =
      if !is_nil(params["id"]) and params["id"] != "" do
        params["id"]
      else
        top_level_category
      end

    {:ok, category} =
      if !is_nil(id) and id != "" do
        Bonfire.Classify.Categories.get(id)
      else
        {:ok, %{}}
      end

    # debug(category)

    {:noreply,
     socket
     |> assign(current_user: current_user(socket))
     |> assign(category: category)
     |> assign(current_context: category)}
  end
end
