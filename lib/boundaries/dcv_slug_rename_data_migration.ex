defmodule Bonfire.Classify.Boundaries.DcvSlugRenameDataMigration do
  @moduledoc """
  Moves any group whose stored `default_content_visibility` names a renamed slug onto the new name.

  A group's membership, visibility and participation are DERIVED from the ACLs on the object, so renaming a slug leaves them alone: the grants did not change, only what we call them, and detection matches on the grants. `default_content_visibility` is the exception, and the only slug this system stores as a string.

  The `*:discoverable` → `*:preview` rename is the reason this exists, and it is a safety net rather than an expected case: the content-visibility dimension has always spelled that role `preview`, and `default_content_visibility_for/1` only ever returns `public` / `local` / `nonfederated` / `members:private`, so no UI could put the other spelling here. Until the boundary write paths were converged, the GraphQL API passed a dimension value through verbatim, so a client could set one directly.

  Separate from `Scaffold.Groups.DataMigration`, which carries the same mapping for instances installing fresh: that one is already recorded in `schema_migrations` everywhere it has run, so editing it would never reach an existing group.

  Safe to re-run: a group whose stored value is not a renamed slug is left untouched.

  Writes a SLUG, where `Scaffold.Groups.DataMigration` resolves the value to an ACL id. That is deliberate rather than an oversight: `store_default_content_visibility/2`, which is what every live write goes through, stores slugs, so this leaves the value in the form the rest of the system produces. The two formats coexisting in that setting predates this and is noted in the group federation plan.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  @renamed %{
    "public:restricted" => "nonfederated",
    "discoverable" => "preview",
    "local:discoverable" => "local:preview",
    "nonfederated:discoverable" => "nonfederated:preview",
    "public:quiet" => "unlisted",
    "local:quiet" => "local:unlisted",
    "nonfederated:quiet" => "nonfederated:unlisted"
  }

  @doc """
  Every `default_content_visibility` slug that has been renamed, as old name => current name.

  Lives here rather than in either migration's body because two of them need it: this one for groups that already ran the group fixtures migration, and `Scaffold.Groups.DataMigration` for groups reaching that migration for the first time. `public:restricted` predates the `*:discoverable` rename and is in the same list because it is the same kind of fact.
  """
  def renamed_slugs, do: @renamed

  @impl DataMigration
  def base_query do
    from(c in Bonfire.Classify.Category,
      where: c.type == :group,
      select: %{id: c.id}
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      async: true,
      batch_size: 500,
      throttle_ms: 1_000,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(results) do
    Enum.each(results, fn group ->
      case Bonfire.Common.Settings.get([:default_content_visibility], nil, scope: group) do
        slug when is_map_key(@renamed, slug) ->
          info(slug, "group #{id(group)}: renaming stored default_content_visibility")

          Bonfire.Common.Settings.put([:default_content_visibility], @renamed[slug], scope: group)

        _ ->
          :skip
      end
    end)
  end
end
