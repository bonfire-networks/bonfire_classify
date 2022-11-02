defmodule Bonfire.Classify.Web.CategoriesLive do
  use Bonfire.UI.Common.Web, :surface_live_view
  alias Bonfire.UI.Me.LivePlugs

  declare_extension("Topics",
    icon: "emojione:books",
    default_nav: [
      Bonfire.Classify.Web.CategoriesLive,
      Bonfire.Classify.Web.LocalCategoriesLive
      # Bonfire.Classify.Web.RemoteCategoriesLive
      # {Bonfire.UI.ValueFlows.ProcessesListLive, process_url: "/coordination/list"}
    ]
  )

  declare_nav_link(l("Overview"), icon: "heroicons-solid:newspaper")

  def mount(params, session, socket) do
    live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      # LivePlugs.LoadCurrentUserCircles,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
      &mounted/3
    ])
  end

  defp mounted(params, _session, socket) do
    {:ok,
     assign(
       socket,
       page: "topics",
       page_title: l("Topics"),
       create_object_type: :category,
       smart_input_prompt: l("Create a topic"),
       categories: [],
       page_info: nil,
       feed: nil,
       #  without_sidebar: true,
       feed_title: nil,
       loading: false,
       smart_input: nil,
       smart_input_opts: nil,
       search_placeholder: nil,
       sidebar_widgets: [
         users: [
           secondary: [
             {Bonfire.Tag.Web.WidgetTagsLive, []}
           ]
         ],
         guests: [
           secondary: nil
         ]
       ]
     )}
  end

  def do_handle_params(%{"tab" => "followed" = tab} = params, _url, socket) do
    current_user = current_user_required!(socket)

    if is_nil(current_user), do: raise(Bonfire.Fail.Auth, :needs_login)

    limit = Bonfire.Common.Config.get(:default_pagination_limit, 10)

    categories =
      Bonfire.Social.Follows.list_my_followed(current_user,
        pagination: %{limit: limit},
        type: Bonfire.Classify.Category
      )

    page =
      categories
      |> e(:edges, [])
      |> Enum.map(&e(&1, :edge, :object, nil))

    # TODO: pagination

    {:noreply,
     socket
     |> assign(
       categories: page,
       page_info: e(categories, :page_info, []),
       page: "topics_followed",
       page_title: l("Followed Topics"),
       selected_tab: "followed",
       feed_title: l("Published in followed topics"),
       limit: limit
     )
     # FIXME: query from all followed topics feeds, not just the current page
     |> assign(
       Bonfire.Social.Feeds.LiveHandler.feed_assigns_maybe_async(
         {"feed:topic", Bonfire.Social.Feeds.feed_ids(:outbox, page)},
         socket
       )
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
       feed_title: l("Published in all known topics"),
       limit: limit
     )
     |> assign(
       Bonfire.Social.Feeds.LiveHandler.feed_assigns_maybe_async(
         {"feed:topic", Bonfire.Tag.Tagged.q_with_type(Bonfire.Classify.Category)},
         socket
       )
       |> debug("feed_assigns_maybe_async")
     )}
  end

  def handle_params(params, uri, socket) do
    # poor man's hook I guess
    with {_, socket} <-
           Bonfire.UI.Common.LiveHandlers.handle_params(params, uri, socket) do
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
     assign(
       socket,
       categories: e(socket.assigns, :categories, []) ++ e(categories, :edges, []),
       page_info: e(categories, :page_info, [])
     )}
  end

  def handle_event("topics_followed:load_more", attrs, socket) do
    limit = e(socket.assigns, :limit, 10)

    categories =
      Bonfire.Social.Follows.list_my_followed(current_user_required!(socket),
        limit: limit,
        after: e(attrs, "after", nil),
        type: Bonfire.Classify.Category
      )

    page =
      categories
      |> e(:edges, [])
      |> Enum.map(&e(&1, :edge, :object, nil))

    # |> debug("TESTTTT")

    {:noreply,
     assign(
       socket,
       categories: e(socket.assigns, :categories, []) ++ page,
       page_info: e(categories, :page_info, [])
     )}
  end

  def handle_event(action, attrs, socket),
    do:
      Bonfire.UI.Common.LiveHandlers.handle_event(
        action,
        attrs,
        socket,
        __MODULE__
      )
end
