defmodule Bonfire.Classify.Repo.Migrations.GroupMemberAccess do
  @moduledoc false
  use Ecto.Migration

  # Gives the members of groups scaffolded before members were granted access the role that lets them read their group, which the global participation ACLs no longer grant.
  def up, do: Bonfire.Classify.Boundaries.GroupMemberAccessDataMigration.up()
  def down, do: :ok
end
