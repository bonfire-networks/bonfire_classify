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

  alias Bonfire.Boundaries.Scaffold.Groups, as: ScaffoldGroups
  alias Bonfire.Boundaries.Controlleds
  alias Bonfire.Social.Objects

  @doc """
  Applies ACL presets for the 4 boundary dimensions and stores `default_content_visibility`
  in the group's settings.

  ## Examples

      iex> GroupBoundary.apply(group, creator, %{
      ...>   membership: "on_request",
      ...>   visibility: "discoverable",
      ...>   participation: "group_members",
      ...>   default_content_visibility: "public"
      ...> })
  """
  def apply(group, creator, %{} = dims, opts \\ []) do
    previous_preset = Keyword.get(opts, :previous_preset)
    visibility = dims[:visibility]
    # When participation is not explicitly set, default based on visibility:
    # global/discoverable groups default to anyone can interact; restricted groups to members-only
    participation = dims[:participation] || default_participation_for(visibility)
    dcv = dims[:default_content_visibility] || default_content_visibility_for(visibility)

    with :ok <- maybe_apply_dimension(group, creator, dims[:membership], previous_preset),
         :ok <- maybe_apply_dimension(group, creator, visibility, previous_preset),
         :ok <- maybe_apply_dimension(group, creator, participation, previous_preset),
         :ok <- maybe_grant_read_to_members(group, visibility),
         :ok <- store_default_content_visibility(group, dcv) do
      :ok
    end
  end

  @doc """
  Returns the default participation slug for a given group visibility slug.
  Global and discoverable groups default to open participation; restricted groups to members only.
  """
  def default_participation_for(visibility) do
    case visibility do
      v when v in ["members_only", "local_unlisted", "unlisted"] -> "group_members"
      "local" <> _ -> "local_contributors"
      _ -> nil
    end
  end

  @doc """
  Returns the default `default_content_visibility` slug for a given group visibility slug.
  """
  def default_content_visibility_for("members_only"), do: "private_members"
  def default_content_visibility_for("local" <> _), do: "local"
  def default_content_visibility_for(_), do: "public"

  @doc """
  Returns `default_content_visibility` slugs that should be disabled for a given group
  visibility slug, because they would expose post content to audiences the group excludes.
  """
  def disabled_default_content_visibility_options(visibility) do
    case visibility do
      "members_only" ->
        ["public", "quiet_public", "preview_public", "local", "quiet_local", "preview_local"]

      v when v in ["local", "local_discoverable", "local_unlisted"] ->
        ["public", "quiet_public", "preview_public"]

      "unlisted" ->
        [
          "public",
          "quiet_public",
          "preview_public",
          "local",
          "quiet_local",
          "preview_local",
          "preview_public"
        ]

      _ ->
        []
    end
  end

  @doc """
  Reads the stored `default_content_visibility` from group settings.
  Other dimensions (membership, visibility, participation) are inferred from ACLs via
  `Bonfire.Boundaries.Presets.preset_boundary_from_acl/2` — no redundant storage needed.
  """
  def read_default_content_visibility(group) do
    Bonfire.Common.Settings.get([:default_content_visibility], nil, scope: group)
  end

  # -- private --

  defp maybe_apply_dimension(_group, _creator, nil, _previous_preset), do: :ok

  defp maybe_apply_dimension(group, creator, slug, previous_preset) do
    case Objects.reset_preset_boundary(
           creator,
           group,
           previous_preset,
           attrs: %{to_boundaries: slug},
           boundaries_caretaker: group
         ) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # For `discoverable`/`preview_*` slugs: the global ACL bundle grants :see to all, but we
  # also need to grant :interact (see+read) to the group's own members circle on the group
  # object itself, so members can read the group page while non-members only see it in lists.
  defp maybe_grant_read_to_members(group, visibility)
       when visibility in [
              "discoverable",
              "local_discoverable",
              "preview_public",
              "preview_local",
              "preview_archipelago"
            ] do
    with {:ok, circle} <- ScaffoldGroups.members_circle(group),
         {:ok, _} <- Controlleds.grant_role(circle, group, :interact, []) do
      :ok
    end
  end

  defp maybe_grant_read_to_members(_group, _visibility), do: :ok

  defp store_default_content_visibility(_group, nil), do: :ok

  defp store_default_content_visibility(group, slug) do
    Bonfire.Common.Settings.put([:default_content_visibility], slug, scope: group)
    :ok
  end
end
