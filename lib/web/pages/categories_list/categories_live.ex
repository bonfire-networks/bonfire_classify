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
      layout_mode: "full",
      categories: [],
      page_info: nil
    )}
  end

  def do_handle_params(%{"tab" => "followed" = tab} = params, _url, socket) do
    limit = Bonfire.Common.Config.get(:default_pagination_limit, 10)

    categories = Bonfire.Social.Follows.list_my_followed(current_user(socket), pagination: %{limit: limit}, type: Bonfire.Classify.Category)

    page = categories
    |> e(:edges, [])
    |> Enum.map(&e(&1, :edge, :object, nil))
    # |> debug("TESTTTT")

    #TODO: pagination

    {:noreply, socket
    |> assign(
      categories: page,
      page_info: e(categories, :page_info, []),
      page: "topics_followed",
      page_title: l("Followed Topics"),
      selected_tab: "followed",
      feed_title: l("Latest in followed topics"),
      limit: limit
    )
    |> assign( # FIXME: query from all followed topics feeds, not just the current page
      Bonfire.Social.Feeds.LiveHandler.feed_assigns_maybe_async({"feed:topic", Bonfire.Social.Feeds.feed_ids(:outbox, page)}, socket)
      |> debug("feed_assigns_maybe_async")
    )}
  end

  def do_handle_params(params, _url, socket) do
    limit = Bonfire.Common.Config.get(:default_pagination_limit, 10)

    {:ok, categories} =
      Bonfire.Classify.GraphQL.CategoryResolver.categories_toplevel(
        %{limit: limit},
        %{context: %{current_user: current_user(socket)}}
      )
      # |> debug()

    {:noreply,
     socket
     |> assign(
      categories: e(categories, :edges, []),
      page_info: e(categories, :page_info, []),
      page: "topics",
      page_title: l("Topics"),
      selected_tab: "all",
      feed_title: l("Latest in all topics"),
      limit: limit
    )
    |> assign(
      Bonfire.Social.Feeds.LiveHandler.feed_assigns_maybe_async({"feed:topic", Bonfire.Tag.Tagged.q_with_type(Bonfire.Classify.Category)}, socket)
      |> debug("feed_assigns_maybe_async")
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

  def handle_event("topics:load_more", attrs, socket) do
    # debug(attrs)
    limit = e(socket.assigns, :limit, 10)

    {:ok, categories} =
      Bonfire.Classify.GraphQL.CategoryResolver.categories_toplevel(
        %{limit: limit, after: [e(attrs, "after", nil)]},
        %{context: %{current_user: current_user(socket)}}
      )
      # |> debug()

    {:noreply,
     socket |> assign(
      categories: e(socket.assigns, :categories, []) ++ e(categories, :edges, []),
      page_info: e(categories, :page_info, [])
    )}
  end

  def handle_event("topics_followed:load_more", attrs, socket) do
    limit = e(socket.assigns, :limit, 10)

    categories = Bonfire.Social.Follows.list_my_followed(current_user(socket), limit: limit, after: e(attrs, "after", nil), type: Bonfire.Classify.Category)

    page = categories
    |> e(:edges, [])
    |> Enum.map(&e(&1, :edge, :object, nil))
    # |> debug("TESTTTT")

    {:noreply, socket
      |> assign(
        categories: e(socket.assigns, :categories, []) ++ page,
        page_info: e(categories, :page_info, [])
      )
    }
  end

  def handle_event(action, attrs, socket), do: Bonfire.UI.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)

end
