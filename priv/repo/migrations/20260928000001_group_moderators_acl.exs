defmodule Bonfire.Classify.Repo.Migrations.GroupModeratorsAcl do
  @moduledoc false
  use Ecto.Migration

  # Creates the `group_moderators_may_moderate` stereotype, which each group's own moderators ACL is stereotyped as (`Scaffold.Groups.moderators_acl/1`). A stereotype declared in config has no row until this runs, and a group's ACL cannot point at one that does not exist.
  def up, do: Bonfire.Boundaries.Scaffold.Instance.upsert_acls()
  def down, do: nil
end
