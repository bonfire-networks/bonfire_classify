defmodule Bonfire.Classify.Repo.Migrations.GroupMembersAcl do
  @moduledoc false
  use Ecto.Migration

  # Creates the `group_members_may_participate` stereotype, which each members-only group's own members ACL is stereotyped as (`Scaffold.Groups.members_acl/1`). A stereotype declared in config has no row until this runs.
  def up, do: Bonfire.Boundaries.Scaffold.Instance.upsert_acls()
  def down, do: nil
end
