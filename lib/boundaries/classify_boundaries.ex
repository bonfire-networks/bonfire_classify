defmodule Bonfire.Classify.Boundaries do
  @moduledoc """
  Manages the 4 boundary dimensions for groups:
    1. membership   — who can join
    2. visibility   — who can see/read the group
    3. participation — who can post/interact
    4. default_content_visibility — how posts in the group federate (stored in group settings;
       used to pre-populate the composer's boundary selector when posting in the group)

  The first 3 dimensions are applied as preset ACL bundles on the group object itself.
  For `discoverable`/`preview_*` visibility slugs an extra per-group :read grant is added
  to the group's own members circle, since "see but not read for non-members" requires a
  targeted circle grant that can't be expressed as a global ACL bundle.

  `default_content_visibility` is only stored in group settings — the post's own boundary
  is set at publish time by the smart input using `to_boundaries`.
  """

  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  alias Bonfire.Boundaries.Scaffold.Groups, as: ScaffoldGroups
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Controlleds
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Social.Objects

  @doc """
  Initialises all boundaries for a newly created category. Called once from `Categories.do_create`.

  For `:group` type: creates the members circle, resolves and applies dimensional ACLs,
  grants the creator `:administer`, grants the members circle access, and stores
  `default_content_visibility`.

  For other types: just grants the creator the `:administer` role on the category.
  """
  def init_boundaries(type, group, creator, attrs) when is_binary(type) do
    case Types.maybe_to_atom(type) do
      type when is_binary(type) ->
        error(type, "Type not supported for boundary initialisation")

      type_atom ->
        init_boundaries(type_atom, group, creator, attrs)
    end
  end

  def init_boundaries(:group, group, creator, attrs) do
    dims =
      Map.take(attrs, [:membership, :visibility, :participation, :default_content_visibility])

    {active_slugs, visibility, participation, default_content_visibility} = resolve_dims(dims)
    info(active_slugs, "init_boundaries :group: boundary slugs")

    with {:ok, _} <- ScaffoldGroups.create_default_boundaries(group, creator),
         :ok <- apply_slugs(group, creator, active_slugs, nil),
         :ok <- grant_creator_administer(creator, group),
         :ok <- maybe_deny_activity_pub(group, visibility, creator),
         :ok <- maybe_apply_participation_custom(group, creator, participation),
         :ok <- grant_member_access(group, visibility, participation, creator),
         :ok <- store_default_content_visibility(group, default_content_visibility),
         :ok <- maybe_store_preset_slug(group, e(attrs, :preset_slug, nil)) do
      {:ok, group}
    end
  end

  defp maybe_store_preset_slug(_group, nil), do: :ok
  defp maybe_store_preset_slug(_group, ""), do: :ok

  defp maybe_store_preset_slug(group, slug) when is_binary(slug) do
    Bonfire.Common.Settings.put([:preset_slug], slug, scope: group)
    :ok
  end

  defp grant_creator_administer(nil, _group), do: :ok

  defp grant_creator_administer(creator, group) do
    Controlleds.grant_role(creator, group, :administer,
      current_user: creator,
      scope: group
    )

    :ok
  end

  def init_boundaries(_type, category, creator, attrs) do
    with :ok <- grant_creator_administer(creator, category),
         :ok <- init_topic_visibility(category, creator, e(attrs, :parent_category, nil)) do
      {:ok, category}
    end
  end

  # A topic nested in a group: mirror the parent group's audience so the same
  # people who can see the group can see (and members can participate in) the topic.
  defp init_topic_visibility(topic, creator, %{id: _} = parent_group) do
    dims = Bonfire.Boundaries.Presets.group_dimension_slugs(parent_group)

    # NOTE: no "global" fallback here — a restrictive group (e.g. members:private)
    # has no detectable visibility slug, and the topic must stay restricted,
    # readable only via the parent's members circle grant below.
    with :ok <- apply_visibility_slug(topic, creator, dims[:visibility]),
         :ok <- grant_parent_members_access(topic, parent_group, dims[:participation], creator) do
      :ok
    end
  end

  # A top-level topic (no parent group): default to public.
  defp init_topic_visibility(topic, creator, _no_parent) do
    apply_visibility_slug(topic, creator, "global")
  end

  # Applies a single visibility preset ACL to the object (skips slugs with no
  # global ACLs, e.g. "members:private" — those rely on per-object circle grants).
  defp apply_visibility_slug(object, creator, slug) do
    preset_acls_map = Bonfire.Common.Config.get!(:preset_acls)

    if is_nil(slug) or preset_acls_map[slug] in [nil, []] do
      :ok
    else
      apply_slugs(object, creator, [slug], nil)
    end
  end

  # Grants the parent group's members circle the same role on the topic that the
  # group grants its members (so members keep read + participation in the topic).
  defp grant_parent_members_access(topic, parent_group, participation, creator) do
    with {:ok, circle} <- ScaffoldGroups.members_circle(parent_group) do
      Controlleds.grant_role(circle, topic, participation_to_role(participation),
        current_user: creator
      )

      :ok
    end
  end

  # Members get :interact when only moderators may post in the group, else :contribute.
  defp participation_to_role("moderators"), do: :interact
  defp participation_to_role(_), do: :contribute

  @doc """
  Derives the layer2 toggle state from a group's current dimension slugs.
  Mirrors the logic in `Bonfire.UI.Groups.GroupBoundaryEditorLive.derive_layer2_state/2`.

  TODO: `:discoverable`, `:anyone_posts`, `:federate` mappings are currently hardcoded here
  and in `dims_from_layer2_overrides/2`; they should instead be driven by config
  (e.g. each `layer2_toggles` entry declaring which dim key/value it maps to).
  """
  def layer2_from_dims(%{} = dims) do
    visibility = dims[:visibility]

    vis_opts =
      Bonfire.Common.Config.get(
        [:preset_dimensions, :visibility, :options],
        %{},
        :bonfire_boundaries
      )

    %{
      discoverable: get_in(vis_opts, [visibility, :role]) == :discover,
      approval_required: dims[:membership] == "on_request",
      anyone_posts: anyone_can_post?(dims[:participation]),
      federate: federated_scope?(visibility)
    }
  end

  @doc """
  Translates a layer2 toggle override map (e.g. `%{discoverable: true}`) into updated
  dimension slug attrs. Mirrors `apply_layer2_to_primitives` in the group boundary editor UI.

  TODO: currently hardcoded — should be config-driven (see `layer2_from_dims/1`).
  """
  def dims_from_layer2_overrides(current_dims, overrides) do
    Enum.reduce(overrides, current_dims, fn
      {key, val}, dims when key in [:discoverable, "discoverable"] ->
        swap_visibility_for_role(dims, if(val, do: :discover, else: :unlisted_read))

      {key, val}, dims when key in [:approval_required, "approval_required"] ->
        Map.put(dims, :membership, if(val, do: "on_request", else: "open"))

      {key, val}, dims when key in [:anyone_posts, "anyone_posts"] ->
        Map.put(dims, :participation, if(val, do: "local:contributors", else: "group_members"))

      _, dims ->
        dims
    end)
  end

  defp swap_visibility_for_role(dims, target_role) do
    current_vis = dims[:visibility]

    vis_opts =
      Bonfire.Common.Config.get(
        [:preset_dimensions, :visibility, :options],
        %{},
        :bonfire_boundaries
      )

    vis_order =
      Bonfire.Common.Config.get(
        [:preset_dimensions, :visibility, :slug_order],
        [],
        :bonfire_boundaries
      )

    current_scope = Bonfire.Boundaries.Presets.slug_scope(current_vis)

    new_vis =
      Enum.find(vis_order, current_vis, fn slug ->
        Bonfire.Boundaries.Presets.slug_scope(slug) == current_scope and
          get_in(vis_opts, [slug, :role]) == target_role
      end)

    Map.put(dims, :visibility, new_vis)
  end

  defp federated_scope?(slug) when is_binary(slug),
    do: Bonfire.Boundaries.Presets.slug_scope(slug) not in ["nonfederated", "local"]

  defp federated_scope?(_), do: false

  defp anyone_can_post?(slug) when is_binary(slug),
    do: slug == "anyone" or String.ends_with?(slug, ":contributors")

  defp anyone_can_post?(_), do: false

  @doc """
  Applies ACL presets for the 4 boundary dimensions and stores `default_content_visibility`
  in the group's settings. Used when editing an existing group's boundaries.

  ## Examples

      iex> Bonfire.Classify.Boundaries.apply(group, creator, %{
      ...>   membership: "on_request",
      ...>   visibility: "discoverable",
      ...>   participation: "group_members",
      ...>   default_content_visibility: "public"
      ...> })
  """
  def apply(group, creator, %{} = dims, opts \\ []) do
    previous_preset = Keyword.get(opts, :previous_preset)
    {active_slugs, visibility, participation, default_content_visibility} = resolve_dims(dims)

    info(active_slugs, "Classify.Boundaries.apply: active ACL slugs to apply")

    with :ok <- apply_slugs(group, creator, active_slugs, previous_preset),
         :ok <- maybe_deny_activity_pub(group, visibility, creator),
         :ok <- maybe_apply_participation_custom(group, creator, participation),
         :ok <- grant_member_access(group, visibility, participation, creator),
         :ok <- store_default_content_visibility(group, default_content_visibility) do
      :ok
    end
  end

  @doc false
  def resolve_dims(%{} = dims) do
    membership = dims[:membership] || "on_request"
    visibility = dims[:visibility] || "local:unlisted"

    participation =
      dims[:participation] || default_participation_for(visibility) || "group_members"

    default_content_visibility =
      dims[:default_content_visibility] || default_content_visibility_for(visibility)

    preset_acls_map = Bonfire.Common.Config.get!(:preset_acls)

    active_slugs =
      [membership, visibility, participation]
      |> Enum.reject(fn slug ->
        is_nil(slug) or slug |> then(&preset_acls_map[&1]) |> Kernel.in([nil, []])
      end)

    {active_slugs, visibility, participation, default_content_visibility}
  end

  @doc """
  Returns the default visibility and participation slugs when a membership slug is selected.
  Used by UI components to cascade dimension defaults.
  """
  def cascade_from_membership("open"), do: %{visibility: "global", participation: "anyone"}

  def cascade_from_membership("local:members"),
    do: %{visibility: "local", participation: "local:contributors"}

  def cascade_from_membership("on_request"),
    do: %{visibility: "global", participation: "group_members"}

  def cascade_from_membership("invite_only"),
    do: %{visibility: "members:private", participation: "group_members"}

  def cascade_from_membership(_), do: %{}

  @doc """
  Returns the default participation slug for a given group visibility slug.
  Global and discoverable groups default to open participation; restricted groups to members only.
  """
  def default_participation_for(visibility) do
    case visibility do
      v when v in ["members:private", "local:unlisted", "unlisted"] -> "group_members"
      "local" <> _ -> "local:contributors"
      _ -> nil
    end
  end

  @doc """
  Returns the default `default_content_visibility` slug for a given group visibility slug.
  """
  def default_content_visibility_for("members:private"), do: "members:private"
  def default_content_visibility_for("local" <> _), do: "local"
  def default_content_visibility_for(_), do: "nonfederated"

  @doc """
  Returns scope strings (e.g. `["global", "nonfederated", "archipelago"]`) that should be
  disabled in the DCV scope selector based on the current group visibility slug.
  """
  def disabled_dcv_scopes(visibility) do
    case visibility do
      "members:private" -> ["global", "nonfederated", "archipelago", "local"]
      v when v in ["local", "local:discoverable", "local:unlisted"] -> ["global", "archipelago"]
      "unlisted" -> ["global", "nonfederated", "archipelago", "local"]
      _ -> []
    end
  end

  @doc """
  Returns `default_content_visibility` slugs that should be disabled for a given group
  visibility slug, because they would expose post content to audiences the group excludes.
  """
  def disabled_default_content_visibility_options(visibility) do
    case visibility do
      "members:private" ->
        [
          "public",
          "nonfederated",
          "nonfederated:preview",
          "nonfederated:quiet",
          "public:quiet",
          "public:preview",
          "local",
          "local:quiet",
          "local:preview"
        ]

      v when v in ["local", "local:discoverable", "local:unlisted"] ->
        ["public", "public:quiet", "public:preview"]

      "unlisted" ->
        [
          "public",
          "nonfederated",
          "nonfederated:preview",
          "nonfederated:quiet",
          "public:quiet",
          "public:preview",
          "local",
          "local:quiet",
          "local:preview"
        ]

      _ ->
        []
    end
  end

  @doc """
  Reads the stored `default_content_visibility` from the object's settings.
  If the object has no stored value (e.g. a topic/subcategory), falls back to
  the parent category's setting, so topics inherit their parent group's DCV.
  """
  def read_default_content_visibility(object, preload \\ true) do
    case Bonfire.Common.Settings.get([:default_content_visibility], nil, scope: object) do
      nil ->
        parent =
          e(object, :parent_category, nil) ||
            if(preload,
              do:
                repo().maybe_preload(object, parent_category: [:settings])
                |> e(:parent_category, nil)
            )

        if parent, do: read_default_content_visibility(parent, false)

      dcv ->
        to_string(dcv)
    end
  end

  @doc """
  Returns the circles to include when publishing a post in a group. Always includes
  the group itself (for feed targeting). Adds the members circle only when the
  group's `default_content_visibility` is restrictive (`members:*`); for permissive
  DCVs the boundary preset already grants non-members `:read`.
  """
  def post_circles_for_group(group) do
    case ScaffoldGroups.members_circle(group) do
      {:ok, circle} ->
        if restrictive_dcv?(read_default_content_visibility(group)),
          do: [id(group), id(circle)],
          else: [id(group)]

      _ ->
        [id(group)]
    end
  end

  defp restrictive_dcv?(slug) when is_binary(slug), do: String.starts_with?(slug, "members:")
  defp restrictive_dcv?(_), do: false

  # -- private --

  defp apply_slugs(group, creator, slugs, previous_preset) do
    # `reset_preset_boundary` only removes one preset, but groups carry three
    # dimension ACL bundles (membership/visibility/participation). Without this,
    # switching presets leaves stale dim ACLs and detection picks the older preset.
    with :ok <- remove_current_dim_acls(group),
         {:ok, _} <-
           Objects.reset_preset_boundary(
             creator,
             group,
             previous_preset,
             attrs: %{to_boundaries: slugs},
             boundaries_caretaker: group
           ) do
      :ok
    end
  end

  defp remove_current_dim_acls(group) do
    current = Bonfire.Boundaries.Presets.group_dimension_slugs(group)

    acls_to_remove =
      [current.membership, current.visibility, current.participation]
      |> Enum.reject(&is_nil/1)
      |> Bonfire.Boundaries.Presets.acls_from_preset_boundary_names()
      |> Enum.uniq()

    case acls_to_remove do
      [] -> :ok
      acls -> with {_count, _} <- Controlleds.remove_acls(group, acls), do: :ok
    end
  end

  # Denies the :activity_pub circle :see/:read on the group for nonfederated visibility slugs.
  # This explicit deny ensures the group is not federated even if AP has a read path elsewhere.
  # Nonfederated slugs are those starting with "nonfederated" (derived from config keys).
  defp maybe_deny_activity_pub(group, visibility, creator) when is_binary(visibility) do
    nonfederated_slugs =
      Bonfire.Common.Config.get!(:preset_acls)
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "nonfederated"))

    if visibility in nonfederated_slugs do
      ap_circle = Bonfire.Boundaries.Scaffold.Instance.activity_pub_circle()

      Controlleds.grant_role(ap_circle, group, :cannot_read, current_user: creator)
      |> info("maybe_deny_activity_pub: denied :activity_pub :read on group #{id(group)}")
    end

    :ok
  end

  defp maybe_deny_activity_pub(_group, _visibility, _creator), do: :ok

  # Grants the members circle an appropriate role on the group object itself.
  # Global ACL bundles control non-member access; this per-object grant ensures members can always
  # at minimum read the group, and in most cases post in it too.
  #
  # Role by participation:
  #   moderators → :interact for members (mods circle gets :contribute separately in apply)
  #   anything else → :contribute (members can read + post)
  #
  defp grant_member_access(group, _visibility, participation, creator) do
    role = participation_to_role(participation)

    with {:ok, circle} <-
           ScaffoldGroups.members_circle(group) |> info("grant_member_access: members_circle") do
      Controlleds.grant_role(circle, group, role, current_user: creator)
      |> info(
        "grant_member_access: grant_role #{role} to circle #{id(circle)} on group #{id(group)}"
      )

      :ok
    end
  end

  # Applies participation for slugs whose ACL signature is *per-group* (a circle
  # owned by the group itself), so they can't live in `:preset_acls` — that map
  # holds global ACL atoms, not per-group circle IDs. Two cases here:
  #   "moderators" — grants the group's moderators circle :contribute on the group.
  #   custom circle ID — grants the named circle :contribute on the group.
  # Slugs already in `:preset_acls` (e.g. "anyone", "local:contributors") are
  # handled by `apply_slugs/4` and no-op here.
  defp maybe_apply_participation_custom(group, creator, "moderators") do
    with {:ok, circle} <- ScaffoldGroups.moderators_circle(group) do
      Controlleds.grant_role(circle, group, :contribute, current_user: creator)
      :ok
    end
  end

  defp maybe_apply_participation_custom(group, creator, participation) do
    if Map.has_key?(Bonfire.Common.Config.get!(:preset_acls), participation) do
      :ok
    else
      Controlleds.grant_role(participation, group, :contribute, current_user: creator)
      :ok
    end
  end

  defp store_default_content_visibility(_group, nil), do: :ok

  defp store_default_content_visibility(group, slug) do
    info(slug, "store_default_content_visibility for group #{id(group)}")

    # acl_names =
    #   case Bonfire.Common.Config.get!(:preset_acls)[slug] do
    #     [_ | _] = names -> names
    #     # fallback: store slug itself if no named ACLs (e.g. "members:private" = no grants)
    #     _ -> slug
    #   end

    Bonfire.Common.Settings.put([:default_content_visibility], slug, scope: group)
    |> info("sdcv: stored #{inspect(slug)} for group #{id(group)}")

    :ok
  end
end
