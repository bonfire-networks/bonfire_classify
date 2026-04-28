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

  For `:group` type: creates the members circle, resolves dimensional ACLs, calls `publish`,
  grants `:interact` to the members circle for discoverable/preview slugs, and stores
  `default_content_visibility`.

  For other types: calls `publish` with the given attrs as-is.
  """
  def init_boundaries(:group, group, creator, attrs) do
    dims =
      Map.take(attrs, [:membership, :visibility, :participation, :default_content_visibility])

    {active_slugs, visibility, participation, default_content_visibility} = resolve_dims(dims)
    info(active_slugs, "init_boundaries :group: boundary slugs")

    # Bypass `publish_and_administer` here: its `set_boundaries` step expects a single
    # preset slug and clobbers our list-of-slugs with the `:default_boundary_preset`.
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
    publish_and_administer(category, creator, attrs)
  end

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

  defp publish_and_administer(category, creator, attrs) do
    if creator,
      do:
        Controlleds.grant_role(creator, category, :administer,
          current_user: creator,
          scope: category
        )

    Bonfire.Classify.publish(creator, :define, category,
      boundaries_caretaker: category,
      attrs: attrs
    )
  end

  defp apply_slugs(group, creator, slugs, previous_preset) do
    # Apply all dimension ACLs in a single call to avoid multiple resets
    case Objects.reset_preset_boundary(
           creator,
           group,
           previous_preset,
           attrs: %{to_boundaries: slugs},
           boundaries_caretaker: group
         ) do
      {:ok, _} -> :ok
      err -> err
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
    role = if participation == "moderators", do: :interact, else: :contribute

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
