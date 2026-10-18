defmodule Bonfire.Classify.Repo.Migrations.TopicMembersFollow do
  use Ecto.Migration

  # lets members follow the topics of a members-only group made before topics got that grant, so they don't get "Could not follow"
  def up() do
    Bonfire.Classify.TopicMembersFollow.DataMigration.up()
  end

  def down, do: :ok
end
