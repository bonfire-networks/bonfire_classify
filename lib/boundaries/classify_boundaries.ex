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

    with {:ok, _} <- ScaffoldGroups.create_default_boundaries(group, creator),
         {:ok, group} <-
           publish_and_administer(group, creator, Map.put(attrs, :to_boundaries, active_slugs)),
         :ok <- maybe_deny_activity_pub(group, visibility, creator),
         :ok <- maybe_apply_participation_custom(group, creator, participation),
         :ok <- grant_member_access(group, visibility, participation, creator),
         :ok <- store_default_content_visibility(group, default_content_visibility) do
      {:ok, group}
    end
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
    |> info("rdcv")
  end

  @doc """
  Returns the circles to include when publishing a post in a group.
  Includes the group itself (for feed targeting) and its members circle (so members
  get read access even when the post boundary restricts non-member access).
  """
  def post_circles_for_group(group) do
    case ScaffoldGroups.members_circle(group) do
      {:ok, circle} -> [id(group), id(circle)]
      _ -> [id(group)]
    end
  end

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

  # Applies participation for named slugs or custom circle IDs.
  # For preset slugs (in preset_acls or slug_order): handled via apply_slugs already.
  # For custom circle IDs: grants :contribute directly via per-object ACL.
  defp maybe_apply_participation_custom(group, creator, "moderators") do
    with {:ok, circle} <- ScaffoldGroups.moderators_circle(group) do
      Controlleds.grant_role(circle, group, :contribute, current_user: creator)
      |> info("maybe_apply_participation_custom: granted :contribute to moderators circle")

      :ok
    end
  end

  defp maybe_apply_participation_custom(group, creator, participation) do
    if Map.has_key?(Bonfire.Common.Config.get!(:preset_acls), participation) do
      # preset slug — already handled via apply_slugs
      :ok
    else
      # treat as a custom circle ID
      Controlleds.grant_role(participation, group, :contribute, current_user: creator)
      |> info("maybe_apply_participation_custom: granted :contribute to circle #{participation}")

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
