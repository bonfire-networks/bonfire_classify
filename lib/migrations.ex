defmodule Bonfire.Classify.Migrations do
  import Ecto.Migration
  import Pointers.Migration

  alias Bonfire.Tag

  # @user Bonfire.Common.Config.get!(:user_schema)

  def up() do

    create_pointable_table(Bonfire.Classify.Category) do
      add(:creator_id, weak_pointer(), null: true)

      add(:caretaker_id, weak_pointer(), null: true)

      # eg. Mamals is a parent of Cat
      add(:parent_category_id, weak_pointer(Bonfire.Classify.Category), null: true)

      # eg. Olive Oil is the same as Huile d'olive
      add(:same_as_category_id, weak_pointer(Bonfire.Classify.Category), null: true)

      # JSONB
      add(:extra_info, :map)

      add(:published_at, :timestamptz)
      add(:deleted_at, :timestamptz)
      add(:disabled_at, :timestamptz)
    end

  end

  def down() do
    drop_pointable_table(Bonfire.Classify.Category)
  end
end
