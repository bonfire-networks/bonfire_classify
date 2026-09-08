defmodule Bonfire.Classify.Boundaries do
  @moduledoc """
  Manages the 4 boundary dimensions for groups:
    1. membership   — who can join
    2. visibility   — who can see/read the group
    3. participation — who can post/interact
    4. default_content_visibility — how posts in the group federate (stored in group settings; used to pre-populate the composer's boundary selector when posting in the group)

  The first 3 dimensions are applied as preset ACL bundles on the group object itself.
  For `discoverable`/`preview_*` visibility slugs an extra per-group :read grant is added to the group's own members circle, since "see but not read for non-members" requires a targeted circle grant that can't be expressed as a global ACL bundle.

  `default_content_visibility` is only stored in group settings — the post's own boundary is set at publish time by the smart input using `to_boundaries`.
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

  For `:group` type: creates the members circle, resolves and applies dimensional ACLs, grants the creator `:administer`, grants the members circle access, and stores `default_content_visibility`.

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
         :ok <- sync_activity_pub_visibility(group, visibility, creator),
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

  # A topic nested in a group: mirror the parent group's audience so the same people who can see the group can see (and members can participate in) the topic.
  defp init_topic_visibility(topic, creator, %{id: _} = parent_group) do
    dims = Bonfire.Boundaries.Presets.group_dimension_slugs(parent_group)

    # NOTE: no "global" fallback here — a restrictive group (e.g. members:private) has no detectable visibility slug, and the topic must stay restricted, readable only via the parent's members circle grant below.
    with :ok <- apply_visibility_slug(topic, creator, dims[:visibility]),
         :ok <- grant_parent_members_access(topic, parent_group, dims[:participation], creator) do
      :ok
    end
  end

  # A top-level topic (no parent group): default to public.
  defp init_topic_visibility(topic, creator, _no_parent) do
    apply_visibility_slug(topic, creator, "global")
  end

  # Applies a single visibility preset ACL to the object (skips slugs with no global ACLs, e.g. "members:private" — those rely on per-object circle grants).
  defp apply_visibility_slug(object, creator, slug) do
    preset_acls_map = Bonfire.Common.Config.get!(:preset_acls)

    if is_nil(slug) or preset_acls_map[slug] in [nil, []] do
      :ok
    else
      apply_slugs(object, creator, [slug], nil)
    end
  end

  # Grants the parent group's members circle the same role on the topic that the group grants its members (so members keep read + participation in the topic).
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

  # the roles `regrant_role/4` is allowed to take away, so changing participation cannot silently revoke anything granted for another reason
  @participation_roles [:interact, :contribute]

  @doc """
  Derives the layer2 toggle state from a group's current dimension slugs.
  Mirrors the logic in `Bonfire.UI.Groups.GroupBoundaryEditorLive.derive_layer2_state/2`.

  TODO: `:discoverable`, `:nonmembers_may_post`, `:federate` mappings are currently hardcoded here and in `dims_from_layer2_overrides/2`; they should instead be driven by config (e.g. each `layer2_toggles` entry declaring which dim key/value it maps to).
  """
  @doc """
  Layer-2 toggle definitions from `:bonfire_classify, :layer2_toggles` config. The `label`/ `description`/`help` strings use `l/1` in config (evaluated once at boot under the default locale), so they're re-localised per-request for display via the shared `localise_tree/3`.
  """
  def layer2_toggles do
    Bonfire.Common.Config.get(:layer2_toggles, [], :bonfire_classify)
    |> Enum.map(&localise_tree(&1, Bonfire.Classify))
  end

  @doc "Ordered list of group preset slugs, from `:bonfire_classify, :group_preset_order` config."
  def group_preset_order do
    Bonfire.Common.Config.get(:group_preset_order, [], :bonfire_classify)
  end

  @doc "Default group preset slug, from `:bonfire_classify, :group_default_preset` config."
  def group_default_preset do
    Bonfire.Common.Config.get(:group_default_preset, nil, :bonfire_classify)
  end

  @doc "Whether a Layer 2 toggle is locked for the given preset (from `layer2_locked` in the preset's config)."
  def layer2_locked?(preset_slug, key) do
    key in Bonfire.Common.Config.get(
      [:group_presets, preset_slug, :layer2_locked],
      [],
      :bonfire_classify
    )
  end

  def layer2_from_dims(%{} = dims) do
    visibility = dims[:visibility]

    vis_opts = Bonfire.Boundaries.Presets.dimension_options(:visibility)

    %{
      discoverable: get_in(vis_opts, [visibility, :role]) == :discover,
      joins_need_approval: dims[:membership] == "on_request",
      nonmembers_may_post: nonmembers_may_post?(dims[:participation]),
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

      {key, val}, dims when key in [:joins_need_approval, "joins_need_approval"] ->
        Map.put(dims, :membership, membership_for_approval(dims, val))

      {key, val}, dims when key in [:nonmembers_may_post, "nonmembers_may_post"] ->
        Map.put(dims, :participation, participation_for_nonmembers(dims, val))

      {key, val}, dims when key in [:federate, "federate"] ->
        target_scope = if val, do: "global", else: "nonfederated"

        dims
        |> swap_dim_for_scope(:visibility, target_scope)
        |> swap_dim_for_scope(:default_content_visibility, target_scope)

      _, dims ->
        dims
    end)
  end

  # `federate` enacts both layer-3 dimensions that carry the federated/nonfederated distinction: the group's own `visibility`, and the `default_content_visibility` its posts get. Moving only the first federates an empty shell, since the group would relay posts whose boundary keeps them off the wire.
  #
  # Both dimensions are laid out as the same scope × role grid, so moving one between scopes means finding its slug in the target scope with the SAME access role: federating a discoverable group leaves it discoverable rather than promoting it to fully readable. The global-scope DCV slugs are spelled `public*` rather than `global*`, which `Presets.slug_scope/1` already resolves.
  #
  # A `members`-scope slug is left alone, as is a dimension that was never set: "members only" has no federated-vs-local counterpart, and taking the same-role slug in another scope would publish a private group.
  defp swap_dim_for_scope(dims, dim, target_scope) do
    current = dims[dim]
    opts = Bonfire.Boundaries.Presets.dimension_options(dim)
    current_role = get_in(opts, [current, :role])

    if is_nil(current_role) or Bonfire.Boundaries.Presets.slug_scope(current) == "members" do
      dims
    else
      new_slug =
        Bonfire.Boundaries.Presets.dimension_slug_order(dim)
        |> Enum.find(current, fn slug ->
          Bonfire.Boundaries.Presets.slug_scope(slug) == target_scope and
            get_in(opts, [slug, :role]) == current_role
        end)

      Map.put(dims, dim, new_slug)
    end
  end

  defp swap_visibility_for_role(dims, target_role) do
    current_vis = dims[:visibility]

    vis_opts = Bonfire.Boundaries.Presets.dimension_options(:visibility)
    vis_order = Bonfire.Boundaries.Presets.dimension_slug_order(:visibility)

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

  # The participation slugs split into two kinds: scoped ones naming a population outside the group (`anyone`, `local:contributors`, `archipelago:contributors`) and member-list ones (`group_members`, `moderators`). That split, not the word "anyone", is what the toggle decides — `local:contributors` lets non-members post while being nothing like "anyone".
  defp nonmembers_may_post?(slug) when is_binary(slug),
    do: slug == "anyone" or String.ends_with?(slug, ":contributors")

  defp nonmembers_may_post?(_), do: false

  # Which population "non-members" means depends on the group's own reach, so the toggle picks the contributors slug in the group's participant scope rather than a fixed one: `anyone` for a federated group, `local:contributors` for a local one.
  #
  # Unlike visibility and DCV, the participation slugs carry no `role`, so there is nothing to match on but the scope — and there is no `nonfederated` participation slug, because a group that does not federate has only local users to draw on (see `participant_scope_for/1`).
  defp participation_for_nonmembers(dims, val) do
    if Types.maybe_to_boolean(val) == true do
      scoped_dim_slug(dims, :participation, &nonmembers_may_post?/1)
    else
      "group_members"
    end
  end

  # Whether a membership slug lets people join without review, as opposed to the process-based `on_request` / `invite_only`. Like participation, these are the scoped ones.
  defp free_to_join?(slug) when is_binary(slug),
    do: slug == "open" or String.ends_with?(slug, ":members")

  defp free_to_join?(_), do: false

  defp membership_for_approval(dims, val) do
    if Types.maybe_to_boolean(val) == true do
      "on_request"
    else
      scoped_dim_slug(dims, :membership, &free_to_join?/1)
    end
  end

  # Picks the slug of a given kind in the group's participant scope, keeping the current one when the scope has none (a `members:private` group has no outward-facing counterpart, and widening it to another scope's slug would publish it).
  defp scoped_dim_slug(dims, dim, kind?) do
    scope = participant_scope_for(dims[:visibility])

    Bonfire.Boundaries.Presets.dimension_slug_order(dim)
    |> Enum.find(dims[dim], fn slug ->
      kind?.(slug) and Bonfire.Boundaries.Presets.slug_scope(slug) == scope
    end)
  end

  # The scope of people who can ACT in a group, derived from the scope of those who can SEE it. The two coincide except for `nonfederated`, which has no participation or membership slug of its own: a group visible to guests on this instance but sent nowhere can only be joined and posted in by local users, so its participant scope is `local`.
  defp participant_scope_for(visibility) do
    case Bonfire.Boundaries.Presets.slug_scope(visibility) do
      "nonfederated" -> "local"
      scope -> scope
    end
  end

  @doc """
  Applies ACL presets for the 4 boundary dimensions and stores `default_content_visibility` in the group's settings. Used when editing an existing group's boundaries.

  ## Examples

      iex> Bonfire.Classify.Boundaries.apply(group, creator, %{
      ...>   membership: "on_request",
      ...>   visibility: "discoverable",
      ...>   participation: "group_members",
      ...>   default_content_visibility: "public"
      ...> })
  """
  def apply(group, creator, %{} = dims, opts \\ []) do
    # Derive it when the caller has not said, rather than defaulting to nil: without a previous preset the old dimension ACLs are left behind, and the caller gets a group that quietly keeps its former boundaries. A caller mid-edit (the settings UI) knows better than the stored state and passes its own.
    previous_preset =
      Keyword.get(opts, :previous_preset) ||
        Bonfire.Boundaries.Presets.preset_slug_from_dims(
          Bonfire.Boundaries.Presets.group_dimension_slugs(group)
        )

    {active_slugs, visibility, participation, default_content_visibility} = resolve_dims(dims)

    info(active_slugs, "Classify.Boundaries.apply: active ACL slugs to apply")

    with :ok <- apply_slugs(group, creator, active_slugs, previous_preset),
         :ok <- sync_activity_pub_visibility(group, visibility, creator),
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

  A `global` group is federated by definition, so its posts default to `public`. This is also the default every MIRRORED remote community currently lands on, since `Categories.create_remote/2` cascades an open membership to `global` visibility: a post written into a mirror exists in order to be sent back to that community, so a non-federating default there means the post never leaves.
  """
  def default_content_visibility_for("members:private"), do: "members:private"
  def default_content_visibility_for("local" <> _), do: "local"
  def default_content_visibility_for("global" <> _), do: "public"
  def default_content_visibility_for(_), do: "nonfederated"

  @doc """
  Returns scope strings (e.g. `["global", "nonfederated", "archipelago"]`) that should be disabled in the DCV scope selector based on the current group visibility slug.
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
  Returns `default_content_visibility` slugs that should be disabled for a given group visibility slug, because they would expose post content to audiences the group excludes.
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

  The object's OWN `:settings` are preloaded first, because `Settings.get(scope: …)` reads what is on the struct and never loads it: handed a group whose settings assoc is unloaded, it returns the default, so a group with a perfectly good stored value reads back as having none. Callers pass whatever the page assigned (`group_live.sface` hands over `@category`), so this cannot assume a loaded assoc. `preload: false` is for the recursive parent call, which was already loaded with its settings.
  """
  def read_default_content_visibility(object, preload \\ true) do
    object = if preload, do: repo().maybe_preload(object, :settings), else: object

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
  Returns the circles to include when publishing a post in a group. Always includes the group itself (for feed targeting). Adds the members circle only when the group's `default_content_visibility` is restrictive (`members:*`); for permissive DCVs the boundary preset already grants non-members `:read`.
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
    # `reset_preset_boundary` only removes one preset, but groups carry three dimension ACL bundles (membership/visibility/participation). Without this, switching presets leaves stale dim ACLs and detection picks the older preset.
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

  # Reconciles the :activity_pub circle's deny on the group with its visibility, in both directions. A nonfederated visibility slug (those starting with "nonfederated", derived from config keys) gets an explicit `:cannot_read` deny, which keeps the group unfederated even if AP has a read path elsewhere; any other slug has that deny lifted.
  #
  # It has to be lifted explicitly because the deny lives on the group's own custom ACL rather than on a dimension ACL, so switching to a federated visibility does NOT drop it the way `remove_previous_preset` drops the others. Without this, a group that starts local can never become federated.
  defp sync_activity_pub_visibility(group, visibility, creator) when is_binary(visibility) do
    nonfederated_slugs =
      Bonfire.Common.Config.get!(:preset_acls)
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "nonfederated"))

    ap_circle = Bonfire.Boundaries.Scaffold.Instance.activity_pub_circle()

    if visibility in nonfederated_slugs do
      Controlleds.grant_role(ap_circle, group, :cannot_read, current_user: creator)
      |> info("sync_activity_pub_visibility: denied :activity_pub :read on group #{id(group)}")
    else
      Controlleds.remove_role(ap_circle, group, :cannot_read, current_user: creator)
      |> info("sync_activity_pub_visibility: lifted any :activity_pub deny on group #{id(group)}")
    end

    :ok
  end

  defp sync_activity_pub_visibility(_group, _visibility, _creator), do: :ok

  # Grants the members circle an appropriate role on the group object itself.
  # Global ACL bundles control non-member access; this per-object grant ensures members can always at minimum read the group, and in most cases post in it too.
  #
  # Role by participation:
  #   moderators → :interact for members (mods circle gets :contribute separately in apply)
  #   anything else → :contribute (members can read + post)
  #
  defp grant_member_access(group, _visibility, participation, creator) do
    role = participation_to_role(participation)

    with {:ok, circle} <-
           ScaffoldGroups.members_circle(group) |> info("grant_member_access: members_circle") do
      regrant_role(circle, group, role, creator)
      # |> info(
      #   "grant_member_access: grant_role #{role} to circle #{id(circle)} on group #{id(group)}"
      # )

      :ok
    end
  end

  # A role GRANTS verbs, and only writes negatives for explicit "cannot" roles, so re-granting a narrower role leaves the wider one's verbs in place: applying `participation: "moderators"` to a group whose members could already post left that `create` grant intact, so "only moderators can post" silently permitted everyone. Clear this subject's grants on the group's own ACL first, so the role applied is the role in effect. Only the per-group circle grants written here need it; the dimension ACLs are swapped wholesale by `apply_slugs/4`.
  defp regrant_role(subject, group, role, creator) do
    with {:ok, acl} <- Acls.get_or_create_object_custom_acl(group, creator) do
      # Remove only the verbs the participation roles can set, never everything this subject holds: an admin who deliberately granted the members circle something else on the group keeps it. (`remove_subject_from_acl/2` would have dropped that too, and `maybe_remove_previous_preset/3` cannot help here, since these are per-object grants rather than a preset's ACLs.)
      for revoke <- @participation_roles, revoke != role do
        Bonfire.Boundaries.Grants.remove_role(subject, acl, revoke)
      end
    end

    Controlleds.grant_role(subject, group, role, current_user: creator)
  end

  # Applies participation for slugs whose ACL signature is *per-group* (a circle owned by the group itself), so they can't live in `:preset_acls`, as that map holds global ACL atoms, not per-group circle IDs. Two cases here:
  # - "moderators": grants the group's moderators circle :contribute on the group.
  # - custom circle ID : grants the named circle :contribute on the group.
  # Slugs already in `:preset_acls` (e.g. "anyone", "local:contributors") are handled by `apply_slugs/4` and no-op here.
  defp maybe_apply_participation_custom(group, creator, "moderators") do
    with {:ok, circle} <- ScaffoldGroups.moderators_circle(group) do
      regrant_role(circle, group, :contribute, creator)
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
