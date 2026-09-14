defmodule Bonfire.Classify.Repo.Migrations.GroupAclSignatures do
  @moduledoc false
  use Ecto.Migration

  # Re-points existing groups from the six deprecated ACL ids to their live replacements, and adds the `:everyone_may_join` / `:everyone_may_request` grants the `open` and `local:members` signatures grew. Without it an existing open group stops matching its own membership and falls back to `invite_only`.
  def up, do: Bonfire.Classify.Boundaries.GroupAclSignaturesDataMigration.up()
  def down, do: :ok
end
