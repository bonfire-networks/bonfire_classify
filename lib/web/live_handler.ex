defmodule Bonfire.Classify.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  alias Bonfire.Classify
  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Tree

  def mounted(params, _session, socket) do
    top_level_category = System.get_env("TOP_LEVEL_CATEGORY", "")

    id =
      if !is_nil(params["id"]) and params["id"] != "" do
        params["id"]
      else
        if !is_nil(params["username"]) and params["username"] != "" do
          params["username"]
        else
          top_level_category
        end
      end

    # TODO: query with boundaries
    {:ok, category} =
      Categories.get(id, [
        :default_incl_deleted,
        current_user: current_user(socket)
      ])

    if category.id == Bonfire.UI.Topics.LabelsLive.label_id() do
      {:ok,
       socket
       |> redirect_to(~p"/labels")}
    else
      type = e(category, :type, nil) || :topic

      category =
        category
        |> repo().maybe_preload([
          :creator,
          parent_category: [
            :profile,
            :character,
            parent_category: [:profile, :character]
          ]
        ])

      # TODO: query children with boundaries

      name = e(category, :profile, :name, l("Untitled topic"))
      object_boundary = Bonfire.Boundaries.Controlleds.get_preset_on_object(category)

      boundary_preset =
        Bonfire.Boundaries.preset_boundary_tuple_from_acl(
          object_boundary,
          Bonfire.Classify.Category
        ) || {"private", l("Private")}

      {:ok,
       assign(
         socket,
         type: type,
         page: name,
         page_title: name,
         back: true,
         object_type: nil,
         feed: nil,
         loading: true,
         hide_tabs: true,
         page_header_aside: [
           {Bonfire.Classify.Web.CategoryHeaderAsideLive, [category: category, showing_within: e(category, :type, :topic)]}
         ],
         #  without_sidebar: true,
         selected_tab: :timeline,
         tab_id: nil,
         #  custom_page_header:
         #    {Bonfire.Classify.Web.CategoryHeaderLive,
         #     category: category, object_boundary: object_boundary},
         smart_input_opts: %{text_suggestion: "+#{e(category, :character, :username, nil)} "},
         category: category,
         canonical_url: canonical_url(category),
         name: name,
         interaction_type: l("follow"),
         #  subcategories: subcategories.edges,
         current_context: category,
         #  reply_to_id: category,
         object_boundary: object_boundary,
         to_boundaries: [{:clone_context, elem(boundary_preset, 1)}],
         boundary_preset: boundary_preset,
         #  create_object_type: :category,
         context_id: ulid(category),
         sidebar_widgets: [
           users: [
             secondary: [
               {Bonfire.UI.Topic.WidgetAboutLive,
                [
                  parent: e(category, :parent_category, :profile, :name, nil),
                  parent_link: path(e(category, :parent_category, nil)),
                  date: "16 Feb",
                  member_count: 1,
                  category: category,
                  boundary_preset: boundary_preset
                ]},
               {Bonfire.UI.Groups.WidgetMembersLive, [mods: [], members: []]}
             ]
           ],
           guests: [
             secondary: nil
           ]
         ]
       )}
    end
  end

  def do_handle_params(%{"tab" => tab} = params, _url, socket)
      when tab in ["posts", "boosts", "timeline"] do
    Bonfire.Social.Feeds.LiveHandler.user_feed_assign_or_load_async(
      tab,
      e(socket.assigns, :category, nil),
      params,
      socket
    )
  end

  def do_handle_params(%{"tab" => "submitted" = tab_id} = params, _url, socket) do
    debug("inbox")

    {:noreply,
     assign(
       socket,
       Bonfire.Social.Feeds.LiveHandler.load_user_feed_assigns(
         "submitted",
         e(socket.assigns, :category, :character, :notifications_id, nil),
         Map.put(
           params,
           :exclude_feed_ids,
           e(socket.assigns, :category, :character, :outbox_id, nil)
         ),
         socket
       )
     )}
  end

  # def do_handle_params(%{"tab" => "settings", "tab_id" => "submitted"} = params, _url, socket) do
  #   # Bonfire.Social.Feeds.LiveHandler.user_feed_assign_or_load_async("timeline", {tab, e(socket.assigns, :category, :character, :notifications_id, nil) |> debug("notifications_id")}, params, socket) # FIXME
  #   debug("QUIQUIQUI")
  #   {:noreply,
  #    assign(
  #      socket,
  #      Bonfire.Social.Feeds.LiveHandler.load_user_feed_assigns(
  #        tab,
  #        e(socket.assigns, :category, :character, :notifications_id, nil),
  #        Map.put(
  #          params,
  #          :exclude_feed_ids,
  #          e(socket.assigns, :category, :character, :outbox_id, nil)
  #        ),
  #        socket
  #      )
  #    )}
  # end

  def do_handle_params(%{"tab" => tab} = params, _url, socket)
      when tab in ["followers", "members"] do
    debug("followers / members")

    {:noreply,
     assign(
       socket,
       Bonfire.Social.Feeds.LiveHandler.load_user_feed_assigns(
         tab,
         e(socket.assigns, :category, nil),
         params,
         socket
       )
     )}
  end

  def do_handle_params(
        %{"tab" => "discover" = tab},
        _url,
        %{assigns: %{category: %{id: parent_category}}} = socket
      ) do
    debug(tab, "list sub-groups/topics")

    with %{edges: list, page_info: page_info} <-
           Categories.list_tree([:default, parent_category: parent_category, tree_max_depth: 1],
             current_user: current_user(socket)
           ) do
      {:noreply,
       assign(socket,
         categories: Classify.arrange_categories_tree(list),
         page_info: page_info,
         selected_tab: tab
       )}
    end
  end

  def do_handle_params(%{"tab" => "discover" = tab}, _url, socket) do
    debug(tab, "list ALL groups/topics")

    with %{edges: list, page_info: page_info} <-
           Categories.list_tree([:default, tree_max_depth: 1], current_user: current_user(socket)) do
      {:noreply,
       assign(socket,
         categories: Classify.arrange_categories_tree(list),
         page_info: page_info,
         selected_tab: tab
       )}
    end
  end

  def do_handle_params(%{"tab" => tab}, _url, socket) do
    debug(tab, "nothing defined")

    {:noreply,
     assign(socket,
       selected_tab: tab
     )}
  end

  def do_handle_params(%{"tab" => tab, "tab_id" => tab_id}, _url, socket) do
    debug(tab, "nothing defined - tab")
    debug(tab_id, "nothing defined - tab_id")

    {:noreply,
     assign(socket,
       selected_tab: tab,
       tab_id: tab_id
     )}
  end

  def do_handle_params(params, _url, socket) do
    debug("default tab or live_action")

    do_handle_params(
      Map.merge(params || %{}, %{
        "tab" => to_string(e(socket, :assigns, :live_action, "timeline"))
      }),
      nil,
      socket
    )
  end

  def new(type \\ :topic, %{"name" => name} = attrs, socket) do
    current_user = current_user_required!(socket)

    if(is_nil(name) or !current_user) do
      error(attrs, "Invalid attrs")

      {:noreply, assign_flash(socket, :error, "Please enter a name...")}
    else
      debug(attrs, "category inputs")

      image_field = if type == :group, do: :image_id, else: :icon_id

      with uploaded_media <-
             live_upload_files(
               current_user,
               attrs["upload_metadata"],
               socket
             ),
           params <-
             attrs
             # |> debug()
             |> Map.merge(attrs["category"] || %{})
             |> Map.drop(["category", "_csrf_token"])
             |> input_to_atoms()
             |> Map.put(:type, type)
             |> maybe_put(image_field, ulid(List.first(uploaded_media)))
             |> debug("create category attrs"),
           {:ok, category} <-
             Categories.create(
               current_user,
               %{category: params, parent_category: e(params, :context_id, nil)}
             ) do
        # TODO: handle errors
        debug(category, "category created")

        {:noreply,
         socket
         |> assign_flash(:info, l("Created!"))
         # change redirect
         |> redirect_to(path(category))}

        # id = e(category, :character, :username, nil) || category.id

        # if(id) do
        #   {:noreply,
        #    socket
        #    |> assign_flash(:info, l("Category created!"))
        #    # change redirect
        #    |> redirect_to("/+" <> id)}
        # else
        #   {:noreply,
        #    redirect_to(
        #      socket,
        #      "/categories/"
        #    )}
        # end
      end
    end
  end

  def handle_event("new", attrs, socket) do
    new(attrs, socket)
  end

  def handle_event("autocomplete", %{"input" => input}, socket) do
    suggestions =
      Bonfire.Tag.Autocomplete.tag_lookup_public(
        input,
        Bonfire.Classify.Category
      )
      |> debug()

    {:noreply,
     assign(socket,
       autocomplete: (e(socket.assigns, :autocomplete, []) ++ suggestions) |> Enum.uniq()
     )}
  end

  def handle_event("input_category", attrs, socket) do
    Bonfire.UI.Common.SmartInputLive.open(socket.assigns[:__context__],
      create_object_type: :category,
      # to_boundaries: [Bonfire.Boundaries.preset_boundary_tuple_from_acl(e(socket.assigns, :object_boundary, nil))],
      activity_inception: "reply_to",
      # TODO: use assigns_merge and send_update to the ActivityLive component within smart_input instead, so that `update/2` isn't triggered again
      # activity: activity,
      object: e(attrs, "parent_id", nil) || e(socket.assigns, :category, nil)
    )

    {:noreply, socket}
  end

  def handle_event("edit", attrs, socket) do
    current_user = current_user_required!(socket)
    category = e(socket.assigns, :category, nil)

    if(!current_user || !category) do
      # error(attrs)
      {:noreply, assign_flash(socket, :error, l("Please log in..."))}
    else
      params = input_to_atoms(attrs)
      debug(attrs, "category to update")

      with {:ok, category} <-
             Categories.update(
               current_user,
               category,
               %{category: params}
             ),
           id when is_binary(id) <-
             e(category, :character, :username, nil) || ulid(category) do
        {:noreply,
         socket
         |> assign_flash(:info, l("Category updated!"))
         # change redirect
         |> redirect_to("/+" <> id)}
      end
    end
  end

  def handle_event("archive", _, socket) do
    category = e(socket.assigns, :category, nil)

    with {:ok, _circle} <-
           Categories.soft_delete(
             category,
             current_user_required!(socket)
           )
           |> debug() do
      {:noreply,
       socket
       |> assign_flash(:info, l("Deleted"))
       |> redirect_to("/topics")}
    end
  end

  def handle_event("validate", _, socket) do
    {:noreply, socket}
  end
end
