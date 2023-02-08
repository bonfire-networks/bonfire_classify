defmodule Bonfire.Classify.Web.LabelsLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  alias Bonfire.Classify.Web.CategoryLive.SubcategoriesLive
  alias Bonfire.Classify.Web.CommunityLive.CommunityCollectionsLive
  alias Bonfire.Classify.Web.CollectionLive.CollectionResourcesLive

  alias Bonfire.UI.Me.LivePlugs

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

  def label_id, do: System.get_env("LABEL_CATEGORY", "7CATEG0RYTHATC0NTA1N1ABE1S")

  defp mounted(params, _session, socket) do
    current_user = current_user(socket)

    label_category = label_id()

    id =
      if !is_nil(params["id"]) and params["id"] != "" do
        params["id"]
      else
        if !is_nil(params["username"]) and params["username"] != "" do
          params["username"]
        else
          label_category
        end
      end

    {:ok, category} =
      with {:error, :not_found} <-
             Bonfire.Classify.Categories.get(id, [:default_incl_deleted]) do
        Bonfire.Classify.Categories.create(current_user, %{
          id: label_category,
          name: "Labels",
          without_character: true
        })
      end

    # TODO: query children with boundaries
    {:ok, subcategories} =
      Bonfire.Classify.GraphQL.CategoryResolver.category_children(
        %{id: ulid!(category)},
        %{limit: 15},
        %{context: %{current_user: current_user}}
      )
      |> debug("subcategories")

    name = e(category, :profile, :name, l("Untitled topic"))
    object_boundary = Bonfire.Boundaries.Controlleds.get_preset_on_object(category)

    {:ok,
     assign(
       socket,
       page: "topics",
       object_type: nil,
       feed: nil,
       without_sidebar: false,
       page_header_aside: [
         {
           Bonfire.Classify.Web.CategoryHeaderAsideLive,
           [category: category]
         }
       ],
       selected_tab: :timeline,
       tab_id: nil,
       #  custom_page_header:
       #    {Bonfire.Classify.Web.CategoryHeaderLive,
       #     category: category, object_boundary: object_boundary},
       create_object_type: :label,
       smart_input_opts: %{prompt: l("New label")},
       category: category,
       canonical_url: canonical_url(category),
       name: name,
       page_title: name,
       interaction_type: l("follow"),
       subcategories: subcategories.edges,
       #  current_context: category,
       #  context_id: ulid(category),
       #  reply_to_id: category,
       object_boundary: object_boundary,
       #  create_object_type: :category,
       sidebar_widgets: [
         users: [
           secondary: [
             {Bonfire.Tag.Web.WidgetTagsLive, []}
           ]
         ],
         guests: [
           secondary: [
             {Bonfire.Tag.Web.WidgetTagsLive, []}
           ]
         ]
       ]
     )}
  end

  def tab(selected_tab) do
    case maybe_to_atom(selected_tab) do
      tab when is_atom(tab) -> tab
      _ -> :timeline
    end

    # |> debug
  end

  def do_handle_params(%{"tab" => tab, "tab_id" => tab_id}, _url, socket) do
    # debug(id)
    {:noreply,
     assign(socket,
       selected_tab: tab,
       tab_id: tab_id
     )}
  end

  def do_handle_params(%{"tab" => tab}, _url, socket) do
    {:noreply,
     assign(socket,
       selected_tab: tab
     )}

    # nothing defined
  end

  def do_handle_params(params, _url, socket) do
    # default tab
    do_handle_params(
      Map.merge(params || %{}, %{"tab" => "timeline"}),
      nil,
      socket
    )
  end

  def handle_params(params, uri, socket),
    do:
      Bonfire.UI.Common.LiveHandlers.handle_params(
        params,
        uri,
        socket,
        __MODULE__,
        &do_handle_params/3
      )

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
