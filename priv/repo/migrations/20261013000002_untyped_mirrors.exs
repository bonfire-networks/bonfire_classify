defmodule Bonfire.Classify.Repo.Migrations.UntypedMirrors do
  use Ecto.Migration

  # mirrors of remote groups made before 23 August, with no type and old or no boundaries
  def up() do
    Bonfire.Classify.UntypedMirrors.DataMigration.up()
  end

  def down, do: :ok
end
