defmodule Bonfire.Classify.Repo.Migrations.AddClassifyIndexes do
  @moduledoc false
use Ecto.Migration 
  use Needle.Migration.Indexable

  def up do
    Bonfire.Classify.Migrations.add_also_known_as_index()
  end

  def down, do: nil
end
