defmodule Bonfire.Classify.Repo.Migrations.GroupModeratorsGrant do
  @moduledoc false
  use Ecto.Migration

  # Gives the moderators of older groups the role that lets them act on their group, after merging the duplicate moderators circles that kept some groups from getting it.
  def up do
    # the migration's own repo, so the merge acts on the database being migrated
    EctoSparkles.DataMigration.Runner.run(
      Bonfire.Boundaries.Scaffold.DuplicateStereotypeCirclesDataMigration,
      repo: repo()
    )

    Bonfire.Classify.Boundaries.GroupModeratorsGrantDataMigration.up()
  end

  def down, do: :ok
end
