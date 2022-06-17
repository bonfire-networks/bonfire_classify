defmodule Bonfire.Classify.Web.Page.Category do
  use Bonfire.UI.Common.Web, :live_view

  alias Bonfire.Classify.Web.Page.Category.SubcategoriesLive
  alias Bonfire.Classify.Web.CommunityLive.CommunityCollectionsLive
  alias Bonfire.Classify.Web.CollectionLive.CollectionResourcesLive

  alias Bonfire.UI.Me.LivePlugs

  def mount(params, session, socket) do
    live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      # LivePlugs.LoadCurrentUserCircles,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
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

  def do_handle_params(%{} = params, uri, socket) do

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

  def handle_params(params, uri, socket) do
    # poor man's hook I guess
    with {_, socket} <- Bonfire.UI.Common.LiveHandlers.handle_params(params, uri, socket) do
      undead_params(socket, fn ->
        do_handle_params(params, uri, socket)
      end)
    end
  end
end
