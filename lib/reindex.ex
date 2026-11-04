defmodule Bonfire.Classify.Reindex do
  @moduledoc """
  (Re)indexes groups, topics and other categories into the search index, in batches.

  Implements `EctoSparkles.DataMigration` (so it reuses the batched, keyset-paginated, throttled runner) and registers as a `Bonfire.Common.ReindexModule` so it runs as part of a full search backfill via `Bonfire.Search.Indexer.reindex_from_db/1`. Needed for categories made before search was on, and for those indexed before the index was picked from what a guest may see of them.
  """
  @behaviour EctoSparkles.DataMigration
  @behaviour Bonfire.Common.ReindexModule
  import Ecto.Query
  use Bonfire.Common.Utils, only: [maybe_apply: 3]
  alias EctoSparkles.DataMigration

  @impl Bonfire.Common.ReindexModule
  def reindex_module, do: __MODULE__

  @impl Bonfire.Common.ReindexModule
  def reindex(opts \\ []), do: DataMigration.Runner.run(__MODULE__, opts)

  # the Category rows: an archived category has no row (its pointer is soft-deleted and Needle deletes the row), so it is left out, as it was taken out of the index when archived. Local and remote alike, since mirrors are indexed when made.
  @impl DataMigration
  def base_query(_opts \\ []) do
    from(c in Bonfire.Classify.Category, as: :main_object)
  end

  @impl DataMigration
  def config do
    # `first_id`: lowest ULID string (Needle.UID-castable), see Bonfire.Me.Users.Reindex.
    %DataMigration.Config{
      batch_size: 50,
      throttle_ms: 2000,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  # the index is picked from each category's boundaries (public when a guest may see it, closed otherwise), and with it its copy in the other index is taken out
  @impl DataMigration
  def migrate(categories) do
    categories
    |> Bonfire.Common.Repo.maybe_preload([:profile, :tag, :parent_category, character: [:peered]])
    |> Enum.each(&maybe_apply(Bonfire.Search, :maybe_index, [&1, nil, []]))
  end
end
