defmodule Bonfire.Classify.Repo.Migrations.DropCategoryLifecycleColumns do
  @moduledoc """
  Drops `category`'s own `deleted_at`, `published_at` and `disabled_at`, which the schema no longer maps: archiving marks the group's pointer deleted instead (existing archives are moved onto their pointers first, `Bonfire.Classify.ArchivedOntoPointers.DataMigration`), and the other two were never set.
  """
  use Ecto.Migration

  def up do
    # the archives first, inline (the data migration isn't async): once `deleted_at` is gone, a group archived through it would read as live
    Bonfire.Classify.ArchivedOntoPointers.DataMigration.maybe_up()

    alter table(:category) do
      remove_if_exists(:deleted_at, :timestamptz)
      remove_if_exists(:published_at, :timestamptz)
      remove_if_exists(:disabled_at, :timestamptz)
    end
  end

  def down do
    alter table(:category) do
      add_if_not_exists(:published_at, :timestamptz)
      add_if_not_exists(:deleted_at, :timestamptz)
      add_if_not_exists(:disabled_at, :timestamptz)
    end
  end
end
