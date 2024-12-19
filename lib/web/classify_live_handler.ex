defmodule Bonfire.Classify.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  alias Bonfire.Classify
  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Tree
  alias Bonfire.Data.Edges.Edge
  use Bonfire.Common.Repo

  declare_extension("Classify",
    icon: "heroicons-solid:collection",
    emoji: "📚",
    description:
      l("Categorise content. Integrates with other extensions such as Tag, Topics, Groups...")
  )

  def mounted(params, _session, socket) do
    current_user = current_user(assigns(socket))
    top_level_category = System.get_env("TOP_LEVEL_CATEGORY", "")

    id =
      if not is_nil(params["id"]) and params["id"] != "" do
        params["id"]
      else
        if not is_nil(params["username"]) and params["username"] != "" do
          params["username"]
        else
          top_level_category
        end
      end

    # TODO: query with boundaries
    with {:ok, category} <-
           Categories.get(id, [
             [:default, preload: :follow_count],
             current_user: current_user
           ]) do
      if category.id == maybe_apply(Bonfire.Label.Labels, :top_label_id, []) do
        {:ok,
         socket
         |> redirect_to(~p"/labels")}
      else
        type = e(category, :type, nil) || :topic

        members_query = Edge |> limit(5)

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
          |> repo().maybe_preload(
            [character: [followers: {members_query, subject: [:profile, :character]}]],
            #  fixme: avoid loading the Needle
            follow_pointers: false
          )

        # |> debug("catttt")

        # TODO: query children/parent with boundaries ^

        moderators = Categories.moderators(id(category))
        # |> debug("modds")

        name = e(category, :profile, :name, l("Untitled topic"))
        object_boundary = Bonfire.Boundaries.Controlleds.get_preset_on_object(category)

        member_count = e(category, :character, :follow_count, :object_count, 0)

        boundary_preset =
          case Bonfire.Boundaries.preset_boundary_tuple_from_acl(
                 object_boundary,
                 Bonfire.Classify.Category
               ) do
            {"private", _} ->
              {"private", l("Private to members of %{group_name}", group_name: name)}

            {id, boundary_name} ->
              {id, boundary_name}

            #  {id, "#{name} (#{boundary_name})"}

            other ->
              warn(other, "no preset detected, assume private")
              {"private", l("Private to members of %{group_name}", group_name: name)}
          end

        date = DatesTimes.date_from_now(category)

        # Enum.map(moderators, & e(&1, :subject_id, nil))
        moderator_ids = Enums.ids(moderators)

        members =
          e(category, :character, :followers, [])
          |> Enum.reject(&(e(&1, :subject_id, nil) in moderator_ids))

        widgets = [
          {Bonfire.Classify.Web.WidgetAboutLive,
           [
             parent: e(category, :parent_category, :profile, :name, nil),
             parent_link: path(e(category, :parent_category, nil)),
             date: date,
             member_count: member_count,
             category: category,
             boundary_preset: boundary_preset
           ]},
          {Bonfire.UI.Groups.WidgetMembersLive, [moderators: moderators, members: members]}
        ]

        widgets =
          if not is_nil(current_user),
            do: [
              users: [
                secondary: widgets
              ]
            ],
            else: [
              guests: [
                secondary: widgets
              ]
            ]

        path = path(category)

        {:ok,
         assign(
           socket,
           type: type,
           page: "topic",
           page_title: name,
           #  extra: l("%{counter} members", counter: member_count),
           date: date,
           member_count: member_count,
           moderators: moderators,
           members: members,
           back: true,
           character_type: :group,
           object_type: nil,
           feed: nil,
           loading: true,
           path: "&",
           #  hide_tabs: true,
           nav_items: Bonfire.Common.ExtensionModule.default_nav(),
           #  page_header_aside: [
           #   {Bonfire.UI.Groups.ComposerGroupLive,
           #    [
           #      category: category
           #    ]},
           #    {Bonfire.Classify.Web.CategoryHeaderAsideLive,
           #     [category: category, boundary_preset: boundary_preset, showing_within: e(category, :type, :topic)]}
           #  ],
           #  without_sidebar: true,
           #  custom_page_header:
           #    {Bonfire.Classify.Web.CategoryHeaderLive,
           #     category: category, object_boundary: object_boundary},
           category: category,
           object: category,
           permalink: path,
           canonical_url: canonical_url(category),
           name: name,
           interaction_type: l("follow"),
           #  subcategories: subcategories.edges,
           current_context: category,
           #  reply_to_id: category,
           object_boundary: object_boundary,
           boundary_preset: boundary_preset,
           #  to_boundaries: [{:clone_context, elem(boundary_preset, 1)}],
           # TODO: add a separate "post in topic" button for this
           #  smart_input_opts: %{text_suggestion: "+#{e(category, :character, :username, nil)} "},
           #  create_object_type: :category,
           context_id: id(category),
           sidebar_widgets: widgets
         )
         |> assign_new(:selected_tab, fn -> :timeline end)
         |> assign_new(:tab_id, fn -> nil end)}
      end
    end
  end

  def handle_params(%{"tab" => tab} = params, _url, socket)
      when tab in ["posts", "boosts", "timeline"] do
    Bonfire.Social.Feeds.LiveHandler.user_feed_assign_or_load_async(
      tab,
      e(assigns(socket), :category, nil),
      params,
      socket
    )
  end

  def handle_params(%{"tab" => "submitted" = _tab} = params, _url, socket) do
    debug("inbox")

    {:noreply,
     Bonfire.Social.Feeds.LiveHandler.assign_feed(
       socket,
       # FIXME to use async/deferred/infinite load
       Bonfire.Social.Feeds.LiveHandler.load_user_feed_assigns(
         "submitted",
         e(assigns(socket), :category, :character, :notifications_id, nil),
         Map.put(
           params,
           :exclude_feed_ids,
           e(assigns(socket), :category, :character, :outbox_id, nil)
         ),
         socket
       )
     )}
  end

  def handle_params(%{"tab" => "settings", "tab_id" => tab_id} = params, _url, socket)
      when tab_id in ["members", "followers", "mentions", "submitted"] do
    socket
    |> assign(tab_id: "settings")
    |> handle_params(Map.merge(params, %{"tab" => tab_id}), nil, ...)
  end

  def handle_params(%{"tab" => tab} = params, _url, socket)
      when tab in ["followers", "members"] do
    debug("followers / members")

    {:noreply,
     Bonfire.Social.Feeds.LiveHandler.assign_feed(
       socket,
       Bonfire.Social.Feeds.LiveHandler.load_user_feed_assigns(
         tab,
         e(assigns(socket), :category, nil),
         params,
         socket
       )
     )}
  end

  def handle_params(
        %{"tab" => "discover" = tab},
        _url,
        %{assigns: %{category: %{id: parent_category}}} = socket
      ) do
    debug(tab, "list sub-groups/topics")

    with %{edges: list, page_info: page_info} <-
           Categories.list_tree([:default, parent_category: parent_category, tree_max_depth: 1],
             current_user: current_user(assigns(socket))
           ) do
      {:noreply,
       assign(socket,
         categories: Classify.arrange_categories_tree(list),
         page_info: page_info,
         selected_tab: tab
       )}
    end
  end

  def handle_params(%{"tab" => "discover" = tab}, _url, socket) do
    debug(tab, "list ALL groups/topics")

    with %{edges: list, page_info: page_info} <-
           Categories.list_tree([:default, tree_max_depth: 1],
             current_user: current_user(assigns(socket))
           ) do
      {:noreply,
       assign(socket,
         categories: Classify.arrange_categories_tree(list),
         page_info: page_info,
         selected_tab: tab
       )}
    end
  end

  def handle_params(%{"tab" => tab, "tab_id" => tab_id}, _url, socket) do
    debug(tab, "nothing defined - tab")
    debug(tab_id, "nothing defined - tab_id")

    {:noreply,
     assign(socket,
       selected_tab: tab,
       tab_id: tab_id
     )}
  end

  def handle_params(%{"tab" => tab}, _url, socket) do
    debug(tab, "nothing defined")

    {:noreply,
     assign(socket,
       selected_tab: tab
     )}
  end

  def handle_params(params, _url, socket) do
    debug("default tab or live_action")

    handle_params(
      Map.merge(params || %{}, %{
        "tab" => to_string(e(assigns(socket), :live_action, "timeline"))
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
             |> maybe_put(image_field, uid(List.first(uploaded_media)))
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

  def handle_event("input_category", attrs, socket) do
    Bonfire.UI.Common.SmartInput.LiveHandler.assign_open(assigns(socket)[:__context__],
      create_object_type: :category,
      # to_boundaries: [Bonfire.Boundaries.preset_boundary_tuple_from_acl(e(assigns(socket), :object_boundary, nil))],
      activity_inception: "reply_to",
      # TODO: use assigns_merge and send_update to the ActivityLive component within smart_input instead, so that `update/2` isn't triggered again
      # activity: activity,
      object: e(attrs, "parent_id", nil) || e(assigns(socket), :category, nil)
    )

    {:noreply, socket}
  end

  def handle_event("edit", attrs, socket) do
    current_user = current_user_required!(socket)
    category = e(assigns(socket), :category, nil)

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
             e(category, :character, :username, nil) || uid(category) do
        {
          :noreply,
          socket
          |> assign_flash(:info, l("Category updated!"))
          # change redirect
          #  |> redirect_to("/+" <> id)
        }
      end
    end
  end

  def handle_event("reset_preset_boundary", params, socket) do
    category =
      e(params, "id", nil) || e(assigns(socket), :object, nil) ||
        e(assigns(socket), :category, nil) ||
        e(assigns(socket), :user, nil)

    with {:ok, _} <-
           Bonfire.Social.Objects.reset_preset_boundary(
             current_user_required!(socket),
             category,
             e(assigns(socket), :boundary_preset, nil) || e(params, "boundary_preset", nil),
             boundaries_caretaker: category,
             attrs: params
           ) do
      {:noreply,
       socket
       |> assign_flash(:info, l("Boundary updated!"))
       |> redirect_to(path(category))}
    end
  end

  def handle_event("archive", _, socket) do
    category = e(assigns(socket), :category, nil)

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

  def set_image(:icon, %{} = object, uploaded_media, assign_field, socket) do
    user = current_user_required!(socket)

    with {:ok, user} <-
           Bonfire.Classify.Categories.update(user, object, %{
             "profile" => %{
               "icon" => uploaded_media,
               "icon_id" => uploaded_media.id
             }
           }) do
      {:noreply,
       socket
       #  |> assign_global(assign_field, deep_merge(user, %{profile: %{icon: uploaded_media}}))
       |> assign_flash(:info, l("Icon changed!"))
       |> assign(src: Bonfire.Files.IconUploader.remote_url(uploaded_media))
       |> send_self_global(
         {assign_field, deep_merge(object, %{profile: %{icon: uploaded_media}})}
       )}
    end
  end

  def set_image(:banner, %{} = object, uploaded_media, assign_field, socket) do
    user = current_user_required!(socket)
    debug(assign_field)

    with {:ok, user} <-
           Bonfire.Classify.Categories.update(user, object, %{
             "profile" => %{
               "image" => uploaded_media,
               "image_id" => uploaded_media.id
             }
           }) do
      {:noreply,
       socket
       |> assign_flash(:info, l("Background image changed!"))
       |> assign(src: Bonfire.Files.BannerUploader.remote_url(uploaded_media))
       #  |> assign_global(assign_field, deep_merge(user, %{profile: %{image: uploaded_media}}) |> debug)
       |> send_self_global(
         {assign_field, deep_merge(object, %{profile: %{image: uploaded_media}})}
       )}
    end
  end
end
