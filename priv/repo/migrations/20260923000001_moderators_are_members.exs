defmodule Bonfire.Classify.Repo.Migrations.ModeratorsAreMembers do
  @moduledoc false
  use Ecto.Migration

  # Makes every existing moderator of a group a member of it, since a members-private group's posts are addressed to its members circle and a moderator who cannot read a post cannot moderate it. Membership only, no follow.
  def up, do: Bonfire.Classify.Boundaries.ModeratorsAreMembersDataMigration.up()
  def down, do: :ok
end
