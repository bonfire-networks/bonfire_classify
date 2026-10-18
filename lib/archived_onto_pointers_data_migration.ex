defmodule Bonfire.Classify.ArchivedOntoPointers.DataMigration do
  @moduledoc """
  Moves groups archived before 18 October onto their pointers, as archiving does now (`Categories.soft_delete/2`).

  They were archived by `Category`'s own `deleted_at` column, which the schema no longer maps, so without this they'd show as live again. Marking each one's pointer deleted makes Needle delete its row, as archiving does now; its mixins hang off the pointer and stay, and `Categories.unarchive/2` recreates the row with the type read from its members circle.

  Run synchronously (`async: false`) by the migration that drops the column, before dropping it (`maybe_up/0`). Safe to re-run: an archive it moved has no row left to select.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  @impl DataMigration
  def base_query do
    # the table rather than the schema, which no longer maps `deleted_at`, joined to the pointer for an id typed as one
    from(p in Needle.Pointer,
      join: c in "category",
      on: c.id == p.id,
      where: not is_nil(c.deleted_at),
      select: %{id: p.id}
    )
  end

  @doc "Whether `category.deleted_at` is still there to move archives from: the migration dropping it runs this first, and this does nothing once it's gone"
  def column_exists? do
    match?(
      {:ok, %{num_rows: n}} when n > 0,
      Ecto.Adapters.SQL.query(
        Bonfire.Common.Repo,
        "SELECT 1 FROM information_schema.columns WHERE table_name = 'category' AND column_name = 'deleted_at'",
        []
      )
    )
  end

  @doc "Moves the archives, if the column is still there"
  def maybe_up, do: if(column_exists?(), do: up(), else: :ok)

  @impl DataMigration
  def config do
    %DataMigration.Config{
      async: false,
      batch_size: 100,
      throttle_ms: 100,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(results) do
    Enum.each(results, fn %{id: id} ->
      with {:ok, pointer} <- Bonfire.Common.Needles.one(id, skip_boundary_check: true) do
        Bonfire.Common.Repo.Delete.soft_delete(pointer)
      else
        other -> debug(other, "no live pointer for an archived category, left as it is")
      end
    end)
  end
end
