defmodule Bonfire.Classify.TopicMembersFollow.DataMigration do
  @moduledoc """
  Lets members follow the topics of a members-only group that were made before topics got the grant (reported on prod as "Could not follow"). A members-only group's visibility grants nothing, so `:follow` on a topic in it only comes from its members circle, whose role carries none: such a topic could be read and posted in by its members but not followed, even by its moderators.

  Each topic with a parent gets what `Bonfire.Classify.Boundaries.grant_parent_members_follow/2` gives it, which is nothing unless the parent's visibility carries no `:follow`.

  Safe to re-run: the grant is an upsert.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  @impl DataMigration
  def base_query do
    from(c in Bonfire.Classify.Category,
      join: t in Bonfire.Classify.Tree,
      on: t.id == c.id,
      where: c.type == :topic and not is_nil(t.parent_id) and t.parent_id != c.id,
      select: %{id: c.id, parent_id: t.parent_id}
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      async: true,
      batch_size: 100,
      throttle_ms: 1_000,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(results) do
    Enum.each(results, &safely_grant/1)
  end

  # one at a time, so a topic that fails loses only itself, not the rest of its batch
  defp safely_grant(%{id: id, parent_id: parent_id} = row) do
    Bonfire.Classify.Boundaries.grant_parent_members_follow(id, parent_id)
  rescue
    e ->
      error(e, "Could not let members follow the topic #{inspect(row)}, going on with the next")
  catch
    kind, reason ->
      error(
        {kind, reason},
        "Could not let members follow the topic #{inspect(row)}, going on with the next"
      )
  end
end
