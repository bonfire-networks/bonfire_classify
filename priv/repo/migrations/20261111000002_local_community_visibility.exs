defmodule Bonfire.Classify.Repo.Migrations.LocalCommunityVisibility do
  @moduledoc false
  use Ecto.Migration

  # Moves the groups made from the `local_community` preset, back when it used the preview visibility, to `nonfederated`, which the preset now uses.
  def up, do: Bonfire.Classify.Boundaries.LocalCommunityVisibilityDataMigration.up()
  def down, do: :ok
end
