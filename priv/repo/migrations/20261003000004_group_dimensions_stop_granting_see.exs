defmodule Bonfire.Classify.Repo.Migrations.GroupDimensionsStopGrantingSee do
  @moduledoc false
  use Ecto.Migration

  # Seeing a group is its visibility's answer, but two other dimensions granted it too: `open` membership (`everyone_may_see_read`) and `anyone` / `local:contributors` participation (the cumulative `contribute` role). So an open or anyone-may-post group was listed whatever its visibility said, including an unlisted one, and readable in a `preview` one.
  #
  # The contribute ACLs were versioned to new ids that grant only the contribute verbs, so their rows have to exist before groups are pointed at them: `upsert_verbs_acls_and_grants/0` first, then the group ACL backfill, which re-points groups to the new ids and takes `everyone_may_see_read` off open ones. Both are safe to re-run.
  def up do
    Bonfire.Boundaries.Scaffold.Instance.upsert_verbs_acls_and_grants()
    Bonfire.Classify.Boundaries.GroupAclSignaturesDataMigration.up()
  end

  def down, do: :ok
end
