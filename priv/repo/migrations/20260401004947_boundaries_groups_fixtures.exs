defmodule Bonfire.Classify.Repo.Migrations.BoundariesGroupsFixturesUp do
  use Ecto.Migration

  def up() do
    Bonfire.Boundaries.Scaffold.Groups.DataMigration.up()
  end

  def down, do: :ok
end
