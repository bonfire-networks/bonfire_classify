defmodule Bonfire.Classify.Repo.Migrations.DcvSlugRename do
  @moduledoc false
  use Ecto.Migration

  # Moves any group whose stored `default_content_visibility` names a renamed slug onto the new name, for the `*:discoverable` → `*:preview` rename. A group's other dimensions are derived from its ACLs and so need nothing; this setting is the one slug stored as a string.
  def up, do: Bonfire.Classify.Boundaries.DcvSlugRenameDataMigration.up()
  def down, do: :ok
end
