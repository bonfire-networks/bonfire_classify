defmodule Bonfire.Classify.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  alias Bonfire.Classify
  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Tree
  alias Bonfire.Data.Edges.Edge
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
    # asks for archived ones ONLY, rather than loading whatever exists and testing `deleted_at` afterwards. `:default_incl_deleted` supplies the usual preloads without the `:not_deleted` restriction; `:deleted` then restricts to archived
    with {:ok, category} <-
           Categories.get(id, [
             [:default_incl_deleted, :deleted, preload: :follow_count],
             skip_boundary_check: true
           ]),
         # only groups have a restore flow; archived topics/labels stay not-visible
         :group <- e(category, :type, nil),
         true <- Bonfire.Classify.ensure_update_allowed(current_user, category) do
      {:ok, category, :archived}
    else
      # `{:error, :not_found}` rather than a bare atom: `mounted/3`'s `with` has no `else`, so whatever this returns propagates to `undead_mount`, and an unrecognised value renders "Sorry, this resulted in something unexpected" instead of a not-found page. Being unable to see a group is an ordinary outcome, not a crash.
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def handle_info({:refresh_membership, group_id}, socket) do
    category = e(socket.assigns, :category, nil)
    group = e(category, :parent_category, nil) || category

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

  # What changes when the visitor joins or leaves the group, shared by `mounted/3` and the `:refresh_membership` message sent after a join/leave.
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
      topic_gate: topic_gate(category, type, view_mode, current_user, membership_slug)
    ]
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

  def mounted(params, _session, socket) do
    connect_params = Phoenix.LiveView.get_connect_params(socket) || %{}

    group_return_to =
      Bonfire.Classify.Web.GroupNavigation.return_to(params, connect_params["_live_referer"])

    current_user = current_user(socket)
    top_level_category = System.get_env("TOP_LEVEL_CATEGORY", "")

    id =
      cond do
        # nested `/group/:id/topic/:topic_id` route: load the TOPIC (its parent group is
        # preloaded below), not the group in `params["id"]`
        not is_nil(params["topic_id"]) and params["topic_id"] != "" -> params["topic_id"]
        not is_nil(params["id"]) and params["id"] != "" -> params["id"]
        not is_nil(params["username"]) and params["username"] != "" -> params["username"]
        true -> top_level_category
      end

    with {:ok, category, view_mode} <- get_visible_category(id, current_user) do
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
            # `character.peered` for the parent's profile hero (rendered on topic pages)
            parent_category: [
              :profile,
              character: [:peered],
              parent_category: [:profile, character: [:peered]]
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
        object_boundary = Bonfire.Boundaries.Controlleds.get_preset_on_object(category)

        boundary_preset =
          Bonfire.Boundaries.Presets.boundary_preset(
            object_boundary,
            Bonfire.Classify.Category,
            {"private", l("Private")}
          )

        date = DatesTimes.date_from_now(category)
        members = e(category, :character, :followers, [])

        parent_category = e(category, :parent_category, nil)

        group_for_about = parent_category || category
        on_topic? = not is_nil(parent_category)
        has_topics_hint? = e(category, :tree, :direct_children_count, 0) > 0

        subcategories =
          if not on_topic? and has_topics_hint? do
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

        # The "About" right-sidebar widget always reflects the group (never the
        # topic). On topic pages we re-source its data from the parent group.
        about_moderators =
          if on_topic? do
            Categories.moderators(id(group_for_about))
            |> repo().maybe_preload([:profile, :character])
          else
            moderators
          end

        # The group's own parent (e.g. when groups are nested). On a topic page
        # this is the group's parent; on a group page it's the same as
        # parent_category.
        about_grandparent =
          if on_topic?, do: e(group_for_about, :parent_category, nil), else: parent_category

        dim_slugs = Bonfire.Boundaries.Presets.group_dimension_slugs(group_for_about)
        preset_slug = Bonfire.Boundaries.Presets.preset_slug_from_dims(dim_slugs)

        widgets = [
          {Bonfire.UI.Groups.GroupTopicsNavLive,
           [group: group_for_about, topics: subcategories, group_return_to: group_return_to]},
          {Bonfire.UI.Groups.WidgetGroupAboutLive,
           [
             parent: e(about_grandparent, :profile, :name, nil),
             parent_link: path(about_grandparent),
             moderators: about_moderators
           ]},
          {Bonfire.UI.Groups.WidgetGroupRulesLive, [id: "group_rules", category: group_for_about]}
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
           group_participation_slug: dim_slugs[:participation],
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
           group_feed_ids: group_feed_ids,
           feed_ids: group_feed_ids,
           current_context: category,
           #  reply_to_id: category,
           object_boundary: object_boundary,
           boundary_preset: boundary_preset,
           sidebar_widgets: widgets
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

    members =
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
    # group managers — creator, :edit, or :mediate (moderators) — may create topics
    with {:ok, parent} <- Categories.get(parent_id, current_user: current_user),
         true <- Bonfire.Classify.ensure_update_allowed(current_user, parent) do
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
    my_memberships =
      if current_user,
        do: Categories.member_of_groups?(current_user, list_of_ids),
        else: %{}

    # `my_follow` is left to `FollowButtonLive`'s own preload, which also finds a pending follow REQUEST (a group on another instance, until its `Accept` arrives) and shows it as one. Computed here from follows alone, a request read as `false`, and since the button skips its preload once `my_follow` is set, it offered "Follow" again and the click asked twice
    # my_follows =
    #   if current_user do
    #     Bonfire.Social.Graph.Follows.get!(current_user, list_of_ids, current_user: current_user)
    #     |> Map.new(fn follow -> {e(follow, :edge, :object_id, nil), true} end)
    #   else
    #     %{}
    #   end

    member_ids = Map.keys(my_memberships)
    remaining_ids = Enum.reject(list_of_ids, &(&1 in member_ids))

    my_requests =
      if current_user && remaining_ids != [],
        do:
          Bonfire.Social.Requests.get_pending!(
            current_user,
            Bonfire.Boundaries.Verbs.get_id!(:join),
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
       %{
         my_membership: my_membership,
         membership: component.membership_value
         # my_follow: Map.get(my_follows, component.object_id, false)
       }}
    end)
  end
end
