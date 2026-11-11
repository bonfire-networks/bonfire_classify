defmodule Bonfire.Classify.Boundaries.LocalCommunityVisibilityDataMigration do
  @moduledoc """
  Makes the groups made from the `local_community` preset readable on this instance.

  The preset used to pair the preview visibility (`nonfederated:preview`) with `local:members` and `local:contributors`, so outsiders only saw the gate. It now uses `nonfederated`, and the groups made from it earlier keep the old visibility until they are moved here. Only a group whose three dimensions are exactly the preset's moves: one that merely shares some of them was set up on purpose.

  The visibility ACLs are added before the old ones come off, so a group is never momentarily left without a visibility. Safe to re-run: once a group reads `nonfederated` it no longer matches.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  alias Bonfire.Boundaries.Controlleds
  use DataMigration

  @from_dims %{
    membership: "local:members",
    visibility: "nonfederated:preview",
    participation: "local:contributors"
  }
  @to_visibility "nonfederated"

  @impl DataMigration
  def base_query do
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
      if Bonfire.Boundaries.Presets.group_dimension_slugs(group) == @from_dims,
        do: move_visibility(group)
    end)
  end

  defp move_visibility(group) do
    preset_acls = Bonfire.Common.Config.get!(:preset_acls)

    Controlleds.add_acls(group, preset_acls[@to_visibility])
    Controlleds.remove_acls(group, preset_acls[@from_dims.visibility])
  end
end
