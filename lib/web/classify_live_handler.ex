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
    current_user = current_user(socket)
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
            :settings,
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

        moderators =
          Categories.moderators(id(category))
          |> repo().maybe_preload([:profile, :character])

        name = e(category, :profile, :name, l("Untitled topic"))
        member_count = Categories.members_count(category)
        object_boundary = Bonfire.Boundaries.Controlleds.get_preset_on_object(category)

        boundary_preset =
          Bonfire.Boundaries.Presets.boundary_preset(
            object_boundary,
            Bonfire.Classify.Category,
            {"private", l("Private")}
          )

        date = DatesTimes.date_from_now(category)
        members = e(category, :character, :followers, [])
        topic_count = e(category, :tree, :direct_children_count, 0)

        parent_category = e(category, :parent_category, nil)

        # On a topic page, load the parent group's children (sibling topics) so the
        # tab bar is consistent between group and topic views. On a group page,
        # load our own children.
        group_for_nav = parent_category || category
        on_topic? = not is_nil(parent_category)

        subcategories =
          if on_topic? || topic_count > 0 do
            Categories.list_tree(
              [
                :default,
                parent_category: id(group_for_nav),
                tree_max_depth: 1,
                preload: :profile,
                preload: :character
              ],
              current_user: current_user
            )
            |> e(:edges, [])
          else
            []
          end

        # The "About" right-sidebar widget always reflects the group (never the
        # topic). On topic pages we re-source its data from the parent group.
        {about_moderators, about_member_count, about_topic_count, about_boundary_preset,
         about_date} =
          if on_topic? do
            grp_mods =
              Categories.moderators(id(group_for_nav))
              |> repo().maybe_preload([:profile, :character])

            grp_preset =
              group_for_nav
              |> Bonfire.Boundaries.Controlleds.get_preset_on_object()
              |> Bonfire.Boundaries.Presets.boundary_preset(
                Bonfire.Classify.Category,
                {"private", l("Private")}
              )

            {grp_mods, Categories.members_count(group_for_nav), length(subcategories), grp_preset,
             DatesTimes.date_from_now(group_for_nav)}
          else
            {moderators, member_count, topic_count, boundary_preset, date}
          end

        # The group's own parent (e.g. when groups are nested). On a topic page
        # this is the group's parent; on a group page it's the same as
        # parent_category.
        about_grandparent =
          if on_topic?, do: e(group_for_nav, :parent_category, nil), else: parent_category

        about_grandparent_boundary_preset =
          if about_grandparent do
            about_grandparent
            |> Bonfire.Boundaries.Controlleds.get_preset_on_object()
            |> Bonfire.Boundaries.Presets.boundary_preset(Bonfire.Classify.Category)
          end

        membership = Bonfire.Boundaries.Presets.membership_slug(group_for_nav)

        widgets = [
          {Bonfire.UI.Groups.WidgetGroupAboutLive,
           [
             category: group_for_nav,
             date: about_date,
             parent: e(about_grandparent, :profile, :name, nil),
             parent_link: path(about_grandparent),
             boundary_preset: about_boundary_preset,
             membership: membership,
             parent_boundary_preset: about_grandparent_boundary_preset,
             member_count: about_member_count,
             topic_count: about_topic_count,
             moderators: about_moderators,
             members: [],
             character_type: type
           ]}
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

        group_feed_ids = Categories.group_feed_ids(category, subcategories)

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
           #  hide_filters: true,

           page_header_aside: [
             {Bonfire.UI.Me.HeroMoreActionsLive,
              [
                character_type: :group,
                boundary_preset: boundary_preset,
                user: if(type == :topic and parent_category, do: parent_category, else: category),
                parent_id: "group_header",
                members: members,
                moderators: moderators,
                permalink: path
              ]}
           ],
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
           subcategories: subcategories,
           group_feed_ids: group_feed_ids,
           feed_ids: group_feed_ids,
           current_context: category,
           #  reply_to_id: category,
           object_boundary: object_boundary,
           boundary_preset: boundary_preset,
           #  to_boundaries: [{:clone_context, elem(boundary_preset, 1)}],
           #  smart_input_opts: %{context_id: id(category)},
           #  create_object_type: :category,
           sidebar_widgets: widgets
         )
         |> assign_new(:selected_tab, fn -> :discussions end)
         |> assign_new(:tab_id, fn -> nil end)}
      end
    end
  end

  def handle_params(%{"tab" => tab} = _params, _url, socket)
      when tab in ["posts", "boosts", "timeline"] do
    category = e(assigns(socket), :category, nil)

    feed_ids =
      e(assigns(socket), :group_feed_ids, nil) || e(category, :character, :outbox_id, nil)

    {:noreply, assign_category_feed(socket, feed_ids, tab, feed_ids: feed_ids)}
  end

  def handle_params(%{"tab" => "discussions" = tab} = _params, _url, socket) do
    category = e(assigns(socket), :category, nil)

    feed_ids =
      e(assigns(socket), :group_feed_ids, nil) || e(category, :character, :outbox_id, nil)

    {:noreply,
     assign_category_feed(socket, feed_ids, tab,
       feed_name: :recent_discussions,
       feed_ids: feed_ids
     )}
  end

  def handle_params(%{"tab" => "submitted" = tab} = _params, _url, socket) do
    debug("inbox")
    category = e(assigns(socket), :category, nil)
    feed_id = e(category, :character, :notifications_id, nil)

    {:noreply,
     assign_category_feed(socket, feed_id, tab,
       exclude_feed_ids: e(category, :character, :outbox_id, nil)
     )}
  end

  def handle_params(%{"tab" => "settings", "tab_id" => tab_id} = params, _url, socket)
      when tab_id in ["members", "followers", "mentions", "submitted"] do
    socket
    |> assign(tab_id: "settings")
    |> handle_params(Map.merge(params, %{"tab" => tab_id}), nil, ...)
  end

  def handle_params(%{"tab" => "members"} = params, _url, socket) do
    debug("members tab")
    category = e(assigns(socket), :category, nil)
    current_user = current_user(socket)
    pagination = input_to_atoms(params)

    requests =
      if id(category) == id(current_user),
        do:
          maybe_apply(Bonfire.Social.Graph.Follows.LiveHandler, :list_requests, [
            current_user,
            pagination
          ]),
        else: []

    members =
      if e(category, :type, nil) == :group do
        Bonfire.Classify.Categories.list_members(category,
          pagination: pagination,
          current_user: current_user
        )
      else
        Bonfire.Social.Graph.Follows.list_followers(category,
          pagination: pagination,
          current_user: current_user
        )
      end
      |> debug("members")

    {:noreply,
     assign(socket,
       loading: false,
       back: "/&#{e(category, :character, :username, nil)}",
       selected_tab: "members",
       feed: List.wrap(requests) ++ e(members, :edges, []),
       page_info: e(members, :page_info, []),
       previous_page_info: e(assigns(socket), :page_info, nil)
     )}
  end

  def handle_params(%{"tab" => tab} = params, _url, socket)
      when tab in ["followers"] do
    debug("followers tab")
    category = e(assigns(socket), :category, nil)

    {:noreply,
     assign(
       socket,
       maybe_apply(
         Bonfire.Social.Graph.Follows.LiveHandler,
         :load_network,
         [tab, category, params, socket],
         fallback_return: [],
         current_user: current_user(socket)
       )
     )}
  end

  def handle_params(%{"tab" => "topics"} = params, url, socket) do
    handle_params(Map.put(params, "tab", "discover"), url, socket)
  end

  def handle_params(%{"tab" => "discover" = tab}, _url, socket) do
    parent_category = e(assigns(socket), :category, :id, nil)
    debug(tab, if(parent_category, do: "list sub-groups/topics", else: "list ALL groups/topics"))

    tree_opts =
      [:default, tree_max_depth: 1] ++
        if(parent_category, do: [parent_category: parent_category], else: [])

    with %{edges: list, page_info: page_info} <-
           Categories.list_tree(tree_opts, current_user: current_user(socket)) do
      {:noreply,
       assign(socket,
         categories:
           list
           |> Categories.filter_named()
           |> Classify.arrange_categories_tree(),
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
        "tab" => to_string(e(assigns(socket), :live_action, "discussions"))
      }),
      nil,
      socket
    )
  end

  defp assign_category_feed(socket, feed_id, tab, extra_filters \\ []) do
    {feed_name, filters} = Keyword.pop(extra_filters, :feed_name, nil)

    socket
    |> assign(
      feed: nil,
      feed_id: feed_id,
      feed_name: feed_name,
      feed_filters: Map.new(filters),
      feed_component_id: nil,
      loading: true,
      selected_tab: tab
    )
  end

  def new(type \\ :topic, %{"name" => name} = attrs, socket) do
    current_user = current_user_required!(socket)

    with :ok <- check_group_permission(type, current_user) do
      if is_nil(name) or !current_user do
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
        end
      end
    else
      {:error, msg} -> {:noreply, assign_flash(socket, :error, msg)}
    end
  end

  @doc "Initialises boundary dimension assigns with sensible defaults. Call from update/2 in components that render BoundaryDimensionLive."
  def init_group_boundary_assigns(socket) do
    current_user = current_user(socket)

    socket
    |> assign_new(:membership, fn -> "local:members" end)
    |> assign_new(:visibility, fn -> "local" end)
    |> assign_new(:participation, fn -> "local:contributors" end)
    |> assign_new(:default_content_visibility, fn -> "local" end)
    |> assign_new(:circles, fn ->
      if current_user do
        Bonfire.Boundaries.Circles.list_my_for_sidebar(current_user,
          exclude_stereotypes: true,
          exclude_built_ins: true
        )
      else
        []
      end
    end)
  end

  defp cascade_membership_defaults(socket, membership) do
    assign(socket, Bonfire.Classify.Boundaries.cascade_from_membership(membership))
  end

  defp sync_default_content_visibility(socket) do
    assign(
      socket,
      :default_content_visibility,
      Bonfire.Classify.Boundaries.default_content_visibility_for(
        e(assigns(socket), :visibility, "local")
      )
    )
  end

  defp check_group_permission(:group, current_user),
    do: Categories.can_create_group?(current_user)

  defp check_group_permission(_type, _current_user), do: :ok

  def handle_event("new", attrs, socket) do
    new(attrs, socket)
  end

  def handle_event("input_category", attrs, socket) do
    Bonfire.UI.Common.SmartInput.LiveHandler.assign_open(assigns(socket)[:__context__],
      create_object_type: :category,
      # to_boundaries: [Bonfire.Boundaries.Presets.preset_boundary_tuple_from_acl(e(assigns(socket), :object_boundary, nil))],
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

  @doc """
  Handles interactive selection of a single boundary dimension, updating the socket assign
  and cascading defaults to dependent dimensions. Used by both the new-group wizard and
  the group settings page via `BoundaryDimensionLive`.
  """
  def handle_event("set_boundary_dimensions", %{"dim" => dim, "slug" => slug}, socket) do
    dim = String.to_existing_atom(dim)
    socket = assign(socket, dim, slug)

    socket =
      if dim == :membership,
        do: cascade_membership_defaults(socket, slug),
        else: socket

    socket =
      if dim in [:membership, :visibility],
        do: sync_default_content_visibility(socket),
        else: socket

    {:noreply, socket}
  end

  def handle_event("set_boundary_scope", %{"dim" => dim, "scope" => scope}, socket) do
    dim = String.to_existing_atom(dim)
    # When a scope is selected, pick the "visible" (base) slug for that scope as default
    # e.g. scope="local" → slug="local", scope="members" → slug="members:private"
    default_slug =
      case scope do
        "members" -> "members:private"
        s -> s
      end

    socket = assign(socket, dim, default_slug)

    socket =
      if dim in [:membership, :visibility],
        do: sync_default_content_visibility(socket),
        else: socket

    {:noreply, socket}
  end

  def handle_event("set_group_boundaries", params, socket) do
    current_user = current_user_required!(socket)

    category =
      e(params, "id", nil) || e(assigns(socket), :object, nil) ||
        e(assigns(socket), :category, nil)

    dims = %{
      membership: params["membership"],
      visibility: params["visibility"],
      participation: params["participation"],
      default_content_visibility: params["default_content_visibility"]
    }

    previous_preset =
      e(assigns(socket), :boundary_preset, nil) || e(params, "boundary_preset", nil)

    case Bonfire.Classify.Boundaries.apply(category, current_user, dims,
           previous_preset: previous_preset
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign_flash(:info, l("Boundary updated!"))
         |> redirect_to(path(category))}

      _ ->
        {:noreply, assign_flash(socket, :error, l("Could not update boundary"))}
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

  def update_many(assigns_sockets, opts \\ []) do
    {first_assigns, _socket} = List.first(assigns_sockets)

    update_many_async(
      assigns_sockets,
      opts ++
        [
          skip_if_set: :my_membership,
          id: id(first_assigns),
          assigns_to_params_fn: &assigns_to_params/1,
          preload_fn: &do_preload/3
        ]
    )
  end

  defp assigns_to_params(assigns) do
    %{
      component_id: assigns.id,
      object_id: e(assigns, :object_id, nil),
      previous_value: e(assigns, :my_membership, nil),
      # TODO: avoid having to query/compute it here
      membership_value:
        e(assigns, :membership_value, nil) ||
          Bonfire.Boundaries.Presets.membership_slug(
            e(assigns, :object, nil) || e(assigns, :object_id, nil)
          )
    }
  end

  defp do_preload(list_of_components, list_of_ids, current_user) do
    my_memberships =
      if current_user,
        do: Categories.member_of_groups?(current_user, list_of_ids),
        else: %{}

    member_ids = Map.keys(my_memberships)
    remaining_ids = Enum.reject(list_of_ids, &(&1 in member_ids))

    my_requests =
      if current_user && remaining_ids != [],
        do:
          Bonfire.Social.Requests.get!(
            current_user,
            Bonfire.Data.Social.Follow,
            remaining_ids,
            preload: false,
            skip_boundary_check: true
          )
          |> Map.new(fn r -> {e(r, :edge, :object_id, nil), true} end),
        else: %{}

    Map.new(list_of_components, fn component ->
      my_membership =
        if(Map.get(my_requests, component.object_id), do: :requested) ||
          Map.get(my_memberships, component.object_id) ||
          component.previous_value ||
          false

      {component.component_id,
       %{my_membership: my_membership, membership_value: component.membership_value}}
    end)
  end
end
