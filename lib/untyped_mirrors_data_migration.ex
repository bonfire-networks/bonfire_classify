defmodule Bonfire.Classify.UntypedMirrors.DataMigration do
  @moduledoc """
  Puts right the mirrors of remote `Group`s made before 23 August, when `Categories.create_remote/2` set no type: an untyped category is shown as a topic, and those mirrors have whatever boundaries the code of the day gave them, some none at all (so people here can't open them).

  Each one gets what a re-fetch of its actor would give it now (`Categories.update_remote_actor/2`): the group scaffold, the boundaries its declarations ask for, and the type they say (a group or a topic), from the actor we already hold rather than a fetch.

  Safe to re-run: a mirror that has a type is no longer selected.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  @impl DataMigration
  def base_query do
    # remote ones only: a local category always had a type
    from(c in Bonfire.Classify.Category,
      join: p in Bonfire.Data.ActivityPub.Peered,
      on: p.id == c.id,
      where: is_nil(c.type),
      select: %{id: c.id}
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
    Enum.each(results, &safely_repair/1)
  end

  # one at a time, so a mirror whose repair raises loses only itself, not the rest of its batch: on bonfire.cafe, syncing one mirror's moderators hit a username already held under another URI, the transaction rolled back, and the raise ended the whole run with 2507 mirrors left
  defp safely_repair(row) do
    repair(row)
  rescue
    e -> error(e, "Could not repair the untyped mirror #{inspect(row)}, going on with the next")
  catch
    kind, reason ->
      error({kind, reason}, "Could not repair the untyped mirror #{inspect(row)}, going on with the next")
  end

  defp repair(%{id: id}) do
    with {:ok, %{type: nil} = category} <-
           Bonfire.Classify.Categories.get(id, skip_boundary_check: true),
         {:ok, %{data: %{"type" => "Group"} = data}} <-
           ActivityPub.Actor.get_cached(pointer: id) do
      Bonfire.Classify.Categories.update_remote_actor(category, %{
        remote_declarations:
          maybe_apply(Bonfire.Federate.ActivityPub.Adapter, :remote_declarations, [data],
            fallback_return: %{}
          )
      })
    else
      other -> debug(other, "not an untyped mirror of a remote Group, left as it is")
    end
  end
end
