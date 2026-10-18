defmodule Bonfire.Classify.Repo.Migrations.UntypedMirrorsAgain do
  use Ecto.Migration

  # the repair of mirrors made before 23 August, run again: the first run (`20261013000002`) ended at the first mirror whose repair raised (on bonfire.cafe, 2507 left untyped), and now goes on past one. Only mirrors still untyped are selected, so where the first run finished this does nothing
  def up() do
    Bonfire.Classify.UntypedMirrors.DataMigration.up()
  end

  def down, do: :ok
end
