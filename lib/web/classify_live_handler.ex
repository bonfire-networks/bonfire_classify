defmodule Bonfire.Classify.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  alias Bonfire.Classify
  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Tree
  use Bonfire.Common.Repo

  declare_extension(l("Classify"),
    icon: "heroicons-solid:collection",
    emoji: "📚",
    description:
      l("Categorise content. Integrates with other extensions such as Tag, Topics, Groups...")
  )

  # `:see`/`:read` checked separately — discoverable grants `:see`, unlisted grants `:read`.
  # One boundarised query for the live case: `Categories.one/2` already gates on `:read`, which is exactly what this page needs, so the check belongs in the fetch rather than a `skip_boundary_check: true` load followed by a separate decision.
  # Archived groups still need the unchecked load, because their rule is NARROWER than `:read`: only someone who could restore one may see it, whereas `:read` would admit anyone who could read the group before it was archived.
  defp get_visible_category(id, current_user) do
    case Categories.get(id, [[:default, preload: :follow_count], current_user: current_user]) do
      {:ok, category} ->
        {:ok, category, :full}

      _not_readable ->
        # `:see` without `:read` is what `discoverable` means: you may know this exists, the contents are for members. Such a visitor still lands on the group's own URL and is offered "Request to join", but sees the same preview the groups directory shows rather than a page built for members.
        # Two fused fetches rather than one unchecked load plus a check, and the second only runs once the first has refused — the same shape `Follows.check_follow/3` uses for `:follow` then `:request`.
        case Categories.get(id, [
               [:default, preload: :follow_count],
               current_user: current_user,
               verbs: [:see]
             ]) do
          {:ok, category} -> {:ok, category, :preview}
          _ -> maybe_get_archived_category(id, current_user)
        end
    end
  end

  defp maybe_get_archived_category(id, current_user) do
    # an archived group has no row, only its pointer and mixins, so it's rebuilt from those (and only groups are archived, so archived topics/labels stay not-visible); its pointer is deleted, so asking who may restore it has to include deleted ones
    with {:ok, category} <- Categories.get_archived(id),
         # only groups have a restore flow, which this page is; archived topics/labels stay not-visible
         #  :group <- Categories.archived_type(category),
         true <-
           Bonfire.Classify.ensure_update_allowed(current_user, category, include_deleted: true) do
      {:ok, category, :archived}
    else
      # `{:error, :not_found}` rather than a bare atom: `mounted/3`'s `with` has no `else`, so whatever this returns propagates to `undead_mount`, and an unrecognised value renders "Sorry, this resulted in something unexpected" instead of a not-found page. Being unable to see a group is an ordinary outcome, not a crash.
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def handle_info({:refresh_membership, group_id}, socket) do
    category = e(socket.assigns, :category, nil)
    # the page's group as `load_category/4` decided it: a topic's parent, or a (sub-)group itself
    group = e(socket.assigns, :frame_group, nil) || category

    if id(group) == group_id do
      user = current_user(socket)

      # refetched only to re-decide `view_mode`: `category` keeps the preloads `mounted/3` added
      case get_visible_category(id(category), user) do
        {:ok, _category, view_mode} ->
          {:noreply,
           assign(
             socket,
             membership_assigns(
               category,
               group,
               e(socket.assigns, :type, :topic),
               view_mode,
               user,
               e(socket.assigns, :group_membership_slug, nil)
             )
           )}

        {:error, :not_found} ->
          {:noreply, redirect_to(socket, "/groups")}
      end
    else
      {:noreply, socket}
    end
  end

  # after a group's pin changes, here or elsewhere: the group header's ⋯ menu reads `group_pins` loaded with the page; called by `Bonfire.Social.Pins.LiveHandler`
  def handle_info({:refresh_pins, object_id}, socket) do
    group = e(socket.assigns, :frame_group, nil) || e(socket.assigns, :category, nil)

    if not is_nil(group) and id(group) == object_id,
      do: {:noreply, assign(socket, group_pins: group_pins(group, current_user(socket)))},
      else: {:noreply, socket}
  end

  # What changes when the visitor joins or leaves the group, shared by `load_category/4` and the `:refresh_membership` message sent after a join/leave.
  defp membership_assigns(category, group, type, view_mode, current_user, membership_slug) do
    member_count = Categories.members_count(category)

    [
      # view_mode: `:full` when the visitor holds `:read`, `:preview` when they only hold `:see` (a `discoverable` group's contents are for members), `:archived` for someone who could restore it. Decided in `get_visible_category/2` from the fetch that succeeded, so the template picks a component rather than re-asking boundaries.
      view_mode: view_mode,
      # cached here rather than checked per render by `:if={@can_create_in_category}`
      can_create_in_category: Bonfire.Boundaries.can?(current_user, :create, category) || false,
      member_count: member_count,
      group_member_count:
        if(id(group) == id(category), do: member_count, else: Categories.members_count(group)),
      # `true`, `:requested` or `false`; `JoinButtonLive` takes it and skips its own lookup
      my_group_membership:
        Categories.my_membership_states(current_user, [id(group)]) |> Map.get(id(group), false),
      topic_gate: topic_gate(category, type, view_mode, current_user, membership_slug)
    ]
  end

  # the rules live in the group's `ExtraInfo`, which the group isn't loaded with
  defp rules_sections(group) do
    extra_info =
      maybe_apply(Bonfire.CommunityRules, :get_extra_info_by_id, [id(group)],
        fallback_return: nil
      )

    maybe_apply(Bonfire.CommunityRules, :get_entity_rules_sections, [extra_info],
      fallback_return: []
    )
  end

  defp group_pins(_group, nil), do: %{instance: false, sidebar: false, can_pin_instance: false}

  defp group_pins(group, current_user) do
    %{
      instance: Bonfire.Social.Pins.pinned?(:instance, group),
      sidebar: Bonfire.Social.Pins.pinned?(current_user, group),
      can_pin_instance: Bonfire.Boundaries.can?(current_user, :mediate, :instance)
    }
  end

  # `Bonfire.UI.Topics.TopicAccessGateLive` offers the parent group's membership options, and only when the visitor may see that group.
  defp topic_gate(category, :topic, :preview, current_user, membership_slug) do
    parent = e(category, :parent_category, nil)

    if e(parent, :type, nil) == :group and Bonfire.Boundaries.can?(current_user, :see, parent) do
      %{
        parent: parent,
        parent_member: not is_nil(current_user) and Categories.member?(current_user, parent),
        membership: membership_slug || "invite_only"
      }
    else
      %{parent: nil, parent_member: false, membership: nil}
    end
  end

  defp topic_gate(_category, _type, _view_mode, _current_user, _membership_slug), do: nil

  @doc """
  Loads the page's group or topic. With `redirect_topics_into_group: true` (`Bonfire.UI.Topics.CategoryLive`), a topic in a group redirects to its in-group URL right after the fetch, before the rest of the page is loaded.
  """
  def mounted(params, _session, socket, opts \\ []) do
    connect_params = Phoenix.LiveView.get_connect_params(socket) || %{}

    group_return_to =
      Bonfire.Classify.Web.GroupNavigation.return_to(params, connect_params["_live_referer"])

    socket = subscribe_to_pins(socket)

    load_category(requested_id(params), group_return_to, socket, opts)
  end

  # the ⋯ menu shows the group's pins to everyone's sidebar and to the viewer's, which can change in another tab or by another admin; `Bonfire.Social.Pins.LiveHandler` hands them to `handle_info({:refresh_pins, _}, _)`
  defp subscribe_to_pins(socket) do
    if user_id = current_user_id(socket),
      do:
        PubSub.subscribe(
          [Bonfire.Social.Pins.pins_topic(:instance), Bonfire.Social.Pins.pins_topic(user_id)],
          socket
        )

    socket
  end

  @doc """
  Reloads the page's category when a live patch moves between a group and one of its topics (`GroupLive` serves both routes, so the topic chips patch rather than navigate). A no-op when the params name the category already loaded, as on the `handle_params` that follows mount.
  """
  def maybe_switch_category(params, socket) do
    category = e(assigns(socket), :category, nil)
    requested = requested_id(params)

    if is_nil(category) or requested in [id(category), e(category, :character, :username, nil)] do
      {:ok, socket}
    else
      load_category(requested, e(assigns(socket), :group_return_to, "/groups"), socket)
    end
  end

  defp requested_id(params) do
    cond do
      # `/group/:id/topic/:topic_id`: the topic, not the group in `params["id"]`
      params["topic_id"] not in [nil, ""] -> params["topic_id"]
      params["id"] not in [nil, ""] -> params["id"]
      params["username"] not in [nil, ""] -> params["username"]
      true -> System.get_env("TOP_LEVEL_CATEGORY", "")
    end
  end

  defp load_category(id, group_return_to, socket, opts \\ []) do
    current_user = current_user(socket)

    with {:ok, category, view_mode} <- get_visible_category(id, current_user) do
      category = repo().maybe_preload(category, character: [:peered])

      redirect_group =
        if opts[:redirect_topics_into_group] == true and
             (e(category, :type, nil) || :topic) == :topic,
           do:
             category
             |> repo().maybe_preload(parent_category: [:character])
             |> e(:parent_category, nil)

      cond do
        category.id == maybe_apply(Bonfire.Label.Labels, :top_label_id, []) ->
          {:ok,
           socket
           |> redirect_to(~p"/labels")}

        # a guest sees a remote group on its own instance, as a guest opening a remote person's profile does (`Bonfire.Me.Profiles.LiveHandler`): our mirror is for people signed in here, who can act on it from here
        is_nil(current_user) and not Bonfire.Social.is_local?(category) ->
          {:ok,
           redirect_to(socket, canonical_url(category),
             type: :maybe_external,
             fallback: "/error"
           )}

        redirect_group ->
          {:ok,
           redirect_to(
             socket,
             Bonfire.Classify.Web.GroupNavigation.link(
               Bonfire.Classify.Web.GroupNavigation.topic_path(redirect_group, category),
               group_return_to
             )
           )}

        true ->
          type = e(category, :type, nil) || :topic

          category =
            category
            |> repo().maybe_preload([
              :creator,
              :settings,
              # `character.peered` for the group header on topic pages
              parent_category: [
                :profile,
                character: [:peered],
                parent_category: [:profile, character: [:peered]]
              ]
            ])

          # |> debug("catttt")

          # TODO: query children/parent with boundaries ^

          name = e(category, :profile, :name, l("Untitled topic"))
          object_boundary = Bonfire.Boundaries.Controlleds.get_preset_on_object(category)

          boundary_preset =
            Bonfire.Boundaries.Presets.boundary_preset(
              object_boundary,
              Bonfire.Classify.Category,
              {"private", l("Private")}
            )

          date = DatesTimes.date_from_now(category)
          parent_category = e(category, :parent_category, nil)

          # by type, not by having a parent: a sub-group has one too, and is still a group page
          on_topic? = type == :topic
          group_for_about = if on_topic?, do: parent_category || category, else: category

          # a topic inside a group renders within the group's frame (its header and topic chips); a top-level topic keeps its own header
          frame_group = if(not on_topic? or not is_nil(parent_category), do: group_for_about)

          # the group's, on its topics too: the header, the widget and the settings are all about the group
          moderators =
            Categories.moderators(id(group_for_about))
            |> repo().maybe_preload([:profile, :character])

          # the first few members (the members circle, not followers: someone can follow without joining), for the header's facepile
          members =
            Categories.list_members(group_for_about, limit: 5, current_user: current_user)
            |> e(:edges, [])

          # a topic's siblings for the chips, or a group's own topics when it has any
          load_topics? =
            if on_topic?,
              do: not is_nil(frame_group),
              else: e(category, :tree, :direct_children_count, 0) > 0

          subcategories =
            if load_topics? do
              Categories.list_tree(
                [
                  :default,
                  parent_category: id(group_for_about),
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

          # the group's own parent, for nested groups
          about_grandparent =
            if on_topic?, do: e(group_for_about, :parent_category, nil), else: parent_category

          dim_slugs = Bonfire.Boundaries.Presets.group_dimension_slugs(group_for_about)
          preset_slug = Bonfire.Boundaries.Presets.preset_slug_from_dims(dim_slugs)

          can_create_topic =
            not is_nil(frame_group) and view_mode == :full and
              Bonfire.Classify.can_create_topic?(current_user, frame_group)

          content_visibility_slug =
            Bonfire.Classify.Boundaries.read_default_content_visibility(group_for_about)

          group_widget =
            {Bonfire.UI.Groups.WidgetGroupLive,
             [
               group: group_for_about,
               parent: about_grandparent,
               moderators: moderators,
               # loaded once here, rather than by the widget on each render
               rules_sections: rules_sections(group_for_about),
               membership_slug: dim_slugs[:membership],
               visibility_slug: dim_slugs[:visibility],
               participation_slug: dim_slugs[:participation],
               content_visibility_slug: content_visibility_slug,
               created: DatesTimes.date_from_now(group_for_about)
             ]}

          path = path(category)

          group_feed_ids =
            if on_topic? do
              Categories.group_feed_ids(category, [])
            else
              Categories.group_feed_ids(category, subcategories)
            end

          {:ok,
           assign(
             socket,
             type: type,
             page: "topic",
             page_title: name,
             #  extra: l("%{counter} members", counter: member_count),
             date: date,
             moderators: moderators,
             members: members,
             group_preset_slug: preset_slug,
             group_membership_slug: dim_slugs[:membership],
             group_visibility_slug: dim_slugs[:visibility],
             back: group_return_to,
             group_return_to: group_return_to,
             character_type: :group,
             object_type: nil,
             feed: nil,
             loading: true,
             path: "&",
             hide_filters: true,

             #  without_sidebar: true,
             #  custom_page_header:
             #    {Bonfire.Classify.Web.CategoryHeaderLive,
             #     category: category, object_boundary: object_boundary},
             category: category,
             object: category,
             permalink: path,
             canonical_url: canonical_url(category),
             name: name,
             interaction_type: "follow",
             subcategories: subcategories,
             can_create_topic: can_create_topic,
             frame_group: frame_group,
             group_feed_ids: group_feed_ids,
             feed_ids: group_feed_ids,
             current_context: category,
             #  reply_to_id: category,
             object_boundary: object_boundary,
             boundary_preset: boundary_preset,
             # the ⋯ menu's, so its template runs no queries; not in `membership_assigns/6`, as joining or leaving doesn't change them
             group_pins: group_pins(group_for_about, current_user),
             sidebar_widgets:
               if(current_user,
                 do: [users: [secondary: [group_widget]]],
                 else: [guests: [secondary: [group_widget]]]
               )
           )
           |> assign(
             membership_assigns(
               category,
               group_for_about,
               type,
               view_mode,
               current_user,
               dim_slugs[:membership]
             )
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

    # who can join decides who sees the list (`Categories.roster_audience/1`); the count stays, and the page says who can see it
    roster_hidden? =
      e(category, :type, nil) == :group and not Categories.roster_visible?(category, current_user)

    members =
      if roster_hidden?,
        do: %{edges: [], page_info: []},
        else:
          Bonfire.Classify.Categories.list_members(category,
            pagination: pagination,
            current_user: current_user
          )
          |> debug("members")

    {:noreply,
     assign(socket,
       loading: false,
       back:
         Bonfire.Classify.Web.GroupNavigation.link(path(category), socket.assigns.group_return_to),
       selected_tab: "members",
       feed: List.wrap(requests) ++ e(members, :edges, []),
       page_info: e(members, :page_info, []),
       previous_page_info: e(assigns(socket), :page_info, nil),
       roster_visibility_slug: if(roster_hidden?, do: Categories.roster_visibility_slug(category))
     )}
  end

  def handle_params(%{"tab" => tab} = params, _url, socket)
      when tab in ["followers"] do
    debug("followers tab")
    category = e(assigns(socket), :category, nil)

    # a group's followers are its roster as much as its members are (`Categories.roster_audience/1`)
    if e(category, :type, nil) == :group and
         not Categories.roster_visible?(category, current_user(socket)) do
      {:noreply,
       assign(socket,
         loading: false,
         selected_tab: tab,
         feed: [],
         page_info: [],
         roster_visibility_slug: Categories.roster_visibility_slug(category)
       )}
    else
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
             :ok <-
               check_parent_permission(e(params, :context_id, nil), current_user),
             [] <- Bonfire.Classify.Boundaries.unchosen_dims(params),
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
        else
          {:error, :unauthorized} ->
            {:noreply,
             assign_flash(
               socket,
               :error,
               l("You don't have permission to create a topic in this group.")
             )}

          [_ | _] ->
            {:noreply,
             assign_flash(
               socket,
               :error,
               l("Please choose an option for each of the group's settings.")
             )}

          # what to fix (eg. which setting was refused), so the person can correct it and submit again; the form keeps what they typed and chose
          {:error, reason} when is_binary(reason) ->
            {:noreply,
             assign_flash(socket, :error, l("Could not create: %{reason}", reason: reason))}

          other ->
            error(other, "Could not create category")
            {:noreply, assign_flash(socket, :error, l("Could not create, please try again."))}
        end
      end
    else
      {:error, msg} -> {:noreply, assign_flash(socket, :error, msg)}
    end
  end

  defp check_parent_permission(nil, _current_user), do: :ok

  defp check_parent_permission(parent_id, current_user) do
    with {:ok, parent} <- Categories.get(parent_id, current_user: current_user),
         true <- Bonfire.Classify.can_create_topic?(current_user, parent) do
      :ok
    else
      _ -> {:error, :unauthorized}
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
      cond do
        is_nil(current_user) ->
          []

        Bonfire.Me.Accounts.is_admin?(current_user) ->
          Bonfire.Boundaries.Circles.list_my_for_sidebar(current_user,
            exclude_stereotypes: true,
            exclude_built_ins: true
          ) ++
            Bonfire.Boundaries.Circles.list_my_for_sidebar(
              Bonfire.Boundaries.Scaffold.Instance.admin_circle(),
              exclude_stereotypes: true,
              exclude_built_ins: true
            )

        true ->
          Bonfire.Boundaries.Circles.list_my_for_sidebar(current_user,
            exclude_stereotypes: true,
            exclude_built_ins: true
          )
      end
    end)
  end

  # replaced by `clear_unavailable_dimensions/1`: the four fields can be picked in any order and only a preset sets several at once, but these made a pick set others too (picking "on request" to join switched who can see the group to "Public (federated)", and picking a visibility reset the default post visibility)
  # defp cascade_membership_defaults(socket, membership) do
  #   assign(socket, Bonfire.Classify.Boundaries.cascade_from_membership(membership))
  # end
  #
  # defp sync_default_content_visibility(socket) do
  #   assign(
  #     socket,
  #     :default_content_visibility,
  #     Bonfire.Classify.Boundaries.default_content_visibility_for(
  #       e(assigns(socket), :visibility, "local")
  #     )
  #   )
  # end

  # A field picked by hand makes the fields the person's own rather than a preset's, so the Custom card is selected (and no preset is submitted, only the four fields). Picking one back to the preset's value doesn't reselect it: clicking the preset reapplies it
  defp picked_by_hand(socket), do: assign(socket, :preset, "custom")

  # Picking one field only reduces what the others offer, so a selection no longer offered is cleared (nothing selected in that field) rather than replaced with another
  defp clear_unavailable_dimensions(socket) do
    visibility = e(assigns(socket), :visibility, nil)

    %{
      membership: Bonfire.Classify.Boundaries.disabled_options_by_reach(:membership, visibility),
      participation:
        Bonfire.Classify.Boundaries.disabled_options_by_reach(:participation, visibility),
      default_content_visibility:
        Bonfire.Classify.Boundaries.disabled_default_content_visibility_options(visibility)
    }
    |> Enum.reduce(socket, fn {dim, unavailable}, socket ->
      if e(assigns(socket), dim, nil) in unavailable, do: assign(socket, dim, nil), else: socket
    end)
  end

  defp check_group_permission(:group, current_user),
    do: Categories.can_create_group?(current_user)

  defp check_group_permission(_type, _current_user), do: :ok

  def handle_event("load_more", %{"context" => "members"} = attrs, socket) do
    category = e(assigns(socket), :category, nil)
    current_user = current_user(socket)

    members =
      Categories.list_members(category,
        current_user: current_user,
        after: e(attrs, "after", nil)
      )

    {:noreply,
     assign(socket,
       feed: e(assigns(socket), :feed, []) ++ e(members, :edges, []),
       page_info: e(members, :page_info, nil)
     )}
  end

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
          |> assign(:category, category)
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
  Handles interactive selection of a single boundary dimension, updating the socket assign and clearing any other field's selection it no longer allows (`clear_unavailable_dimensions/1`). Used by both the new-group wizard and the group settings page via `BoundaryDimensionLive`.
  """
  def handle_event("set_boundary_dimensions", %{"dim" => dim, "slug" => slug}, socket) do
    dim = String.to_existing_atom(dim)
    {:noreply, socket |> assign(dim, slug) |> clear_unavailable_dimensions() |> picked_by_hand()}
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

    {:noreply,
     socket |> assign(dim, default_slug) |> clear_unavailable_dimensions() |> picked_by_hand()}
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

    # the form has already folded any layer-2 toggle into these dims, so there are no `:overrides` to pass. `previous_preset` comes from the assigns because a caller mid-edit knows what it is starting from better than detection does
    case Bonfire.Classify.Boundaries.apply_changes(category, current_user, %{dims: dims},
           previous_preset: previous_preset
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign_flash(:info, l("Boundary updated!"))
         |> redirect_to(path(category))}

      {:error, :unauthorized} ->
        {:noreply,
         assign_flash(
           socket,
           :error,
           l("You don't have permission to change this group's boundaries.")
         )}

      # what to fix (eg. which setting was refused), so the person can correct it and save again; the form keeps their choices
      {:error, reason} when is_binary(reason) ->
        {:noreply,
         assign_flash(socket, :error, l("Could not update boundary: %{reason}", reason: reason))}

      _ ->
        {:noreply, assign_flash(socket, :error, l("Could not update boundary"))}
    end
  end

  def handle_event("toggle_auto_join", %{"group_id" => group_id, "enabled" => _}, socket) do
    Categories.set_auto_join_new_users(group_id, true, current_user: current_user(socket))
    {:noreply, assign_flash(socket, :info, l("Auto-join enabled."))}
  end

  def handle_event("toggle_auto_join", %{"group_id" => group_id}, socket) do
    Categories.set_auto_join_new_users(group_id, false, current_user: current_user(socket))
    {:noreply, assign_flash(socket, :info, l("Auto-join disabled."))}
  end

  def handle_event("archive", _, socket) do
    category = e(assigns(socket), :category, nil)

    with {:ok, _circle} <-
           Categories.soft_delete(category, current_user_required!(socket)) do
      {:noreply,
       socket
       |> assign_flash(:info, l("Archived"))
       |> redirect_to("/groups")}
    end
  end

  def handle_event("unarchive", _, socket) do
    category = e(assigns(socket), :category, nil)

    with {:ok, category} <-
           Categories.unarchive(category, current_user_required!(socket)) do
      {:noreply,
       socket
       |> assign_flash(:info, l("Restored"))
       |> redirect_to(path(category) || "/groups")}
    else
      _ ->
        {:noreply, assign_flash(socket, :error, l("Sorry, you cannot restore this group."))}
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
      # TODO: defer this lookup into `do_preload/3` so it batches with the other queries instead of running per-component on the LV process
      membership_value:
        e(assigns, :membership, nil) ||
          Bonfire.Boundaries.Presets.membership_slug(
            e(assigns, :object, nil) || e(assigns, :object_id, nil)
          )
    }
  end

  defp do_preload(list_of_components, list_of_ids, current_user) do
    my_states = Categories.my_membership_states(current_user, list_of_ids)

    # `my_follow` is left to `FollowButtonLive`'s own preload, which also finds a pending follow REQUEST (a group on another instance, until its `Accept` arrives) and shows it as one. Computed here from follows alone, a request read as `false`, and since the button skips its preload once `my_follow` is set, it offered "Follow" again and the click asked twice
    # my_follows =
    #   if current_user do
    #     Bonfire.Social.Graph.Follows.get!(current_user, list_of_ids, current_user: current_user)
    #     |> Map.new(fn follow -> {e(follow, :edge, :object_id, nil), true} end)
    #   else
    #     %{}
    #   end

    Map.new(list_of_components, fn component ->
      my_membership =
        Map.get(my_states, component.object_id) ||
          component.previous_value ||
          false

      {component.component_id,
       %{
         my_membership: my_membership,
         membership: component.membership_value
         # my_follow: Map.get(my_follows, component.object_id, false)
       }}
    end)
  end
end
