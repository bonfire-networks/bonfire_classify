defmodule Bonfire.Boundaries.Scaffold.Groups.DataMigration do
  @moduledoc """
  Backfills the `group_members` stereotype circle for all existing groups (Categories with
  `type: :group`) that were created before the scaffold was introduced.

  Safe to re-run: groups that already have a members circle are excluded by the query,
  so the batch shrinks to zero naturally.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  @impl DataMigration
  def base_query do
    # Query all groups — get_or_create_stereotype_circle is idempotent,
    # so running this on groups that already have a members circle is safe.
    from(c in Bonfire.Classify.Category,
      where: c.type == :group,
      select: %{id: c.id}
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      async: true,
      batch_size: 500,
      throttle_ms: 1_000,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(results) do
    Enum.each(results, fn group ->
      # backfill existing followers into the members circle
      case Bonfire.Boundaries.Scaffold.Groups.create_default_boundaries(group) do
        {:ok, circle} ->
          Bonfire.Social.Graph.Follows.list_followers(group,
            preload: :subject_id_only,
            paginate: false
          )
          |> List.flatten()
          |> Enum.each(fn follower ->
            Bonfire.Boundaries.Circles.add_to_circles(follower, circle)
          end)

          migrate_dcv(group)

        _ ->
          :skip
      end

      Process.sleep(100)
    end)
  end

  # Backfills default_content_visibility for existing groups.
  # If stored as an old slug string (e.g. "public:restricted"), rename to new slug.
  # If nil, derive from existing boundary preset and store as ACL ID.
  defp migrate_dcv(group) do
    existing = Bonfire.Common.Settings.get([:default_content_visibility], nil, scope: group)

    new_value =
      case existing do
        # Rename old slug → new slug, then resolve to ACL ID
        "public:restricted" ->
          resolve_dcv_to_acl_id("nonfederated")

        # Already a new slug — resolve to ACL ID if it looks like a slug (not already an ID)
        slug when is_binary(slug) and byte_size(slug) < 40 ->
          resolve_dcv_to_acl_id(slug)

        # nil — derive from preset
        nil ->
          slug =
            case Bonfire.Boundaries.Presets.preset_boundary_from_acl(
                   group,
                   Bonfire.Classify.Category
                 ) do
              {preset, _} when preset in ["open", "visible"] -> "nonfederated"
              preset when preset in ["open", "visible"] -> "nonfederated"
              {preset, _} when preset in ["private"] -> "members:private"
              preset when preset in ["private"] -> "members:private"
              _ -> "nonfederated"
            end

          resolve_dcv_to_acl_id(slug)

        # Already an ACL ID (long binary) — no change needed
        _ ->
          nil
      end

    if new_value do
      Bonfire.Common.Settings.put([:default_content_visibility], new_value, scope: group)
    end
  end

  defp resolve_dcv_to_acl_id(slug) do
    case Bonfire.Common.Config.get!(:preset_acls)[slug] do
      [acl_name | _] -> Bonfire.Boundaries.Acls.get_id(acl_name)
      _ -> slug
    end
  end
end
