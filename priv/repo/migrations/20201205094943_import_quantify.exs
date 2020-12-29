defmodule Bonfire.Repo.Migrations.ImportQuantify do
  use Ecto.Migration

  def change do
    if Code.ensure_loaded?(Bonfire.Classify.Migrations) do
       Bonfire.Classify.Migrations.change
       Bonfire.Classify.Migrations.change_measure
    end
  end
end
