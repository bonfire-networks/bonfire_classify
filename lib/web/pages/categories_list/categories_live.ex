defmodule Bonfire.Classify.Web.CategoriesLive do
  use Bonfire.UI.Common.Web, :surface_live_view
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

    {:ok,
     socket |> assign(
      page: "topics",
      page_title: l("Topics"),
      categories: []
    )}
  end

  def do_handle_params(%{"tab" => "followed" = tab} = params, _url, socket) do
    limit = 50

    categories = Bonfire.Social.Follows.list_my_followed(current_user(socket), pagination: %{limit: limit}, type: Bonfire.Classify.Category)
    |> e(:edges, [])
    |> Enum.map(&e(&1, :edge, :object, nil))
    |> debug("TESTTTT")

    #TODO: pagination

    {:noreply, socket
      |> assign(
        categories: categories,
        page: "topics_followed",
        page_title: l("Followed Topics"),
        limit: limit
      )
    }
  end

  def do_handle_params(params, _url, socket) do
    limit = 50

    {:ok, categories} =
      Bonfire.Classify.GraphQL.CategoryResolver.categories_toplevel(
        %{limit: limit},
        %{context: %{current_user: current_user(socket)}}
      )

    #TODO: pagination

    {:noreply,
     socket |> assign(
      categories: e(categories, :edges, []),
      page_title: l("Topics"),
      limit: limit
    )}

  end

  def handle_params(params, uri, socket) do
    # poor man's hook I guess
    with {_, socket} <- Bonfire.UI.Common.LiveHandlers.handle_params(params, uri, socket) do
      undead_params(socket, fn ->
        do_handle_params(params, uri, socket)
      end)
    end
  end

  def handle_event(action, attrs, socket), do: Bonfire.UI.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)

end
