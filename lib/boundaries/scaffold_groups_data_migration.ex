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

          backfill_default_content_visibility(group)

        _ ->
          :skip
      end

      Process.sleep(100)
    end)
  end

  # Derive default_content_visibility from the group's existing boundary preset.
  # Groups with no detectable preset default to "public".
  defp backfill_default_content_visibility(group) do
    existing = Bonfire.Common.Settings.get([:default_content_visibility], nil, scope: group)

    if is_nil(existing) do
      slug =
        case Bonfire.Boundaries.Presets.preset_boundary_from_acl(group, Bonfire.Classify.Category) do
          {preset, _} when preset in ["open"] -> "public"
          preset when preset in ["open"] -> "public"
          {preset, _} when preset in ["visible"] -> "public"
          preset when preset in ["visible"] -> "public"
          {preset, _} when preset in ["private"] -> "private_members"
          preset when preset in ["private"] -> "private_members"
          _ -> "public"
        end

      Bonfire.Common.Settings.put([:default_content_visibility], slug, scope: group)
    end
  end
end
