# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Classify.Category do

  use Pointers.Pointable,
    otp_app: :commons_pub,
    source: "category",
    table_id: "TAGSCANBECATEG0RY0RHASHTAG"

  import Flexto

  @user Bonfire.Common.Config.get!(:user_schema)

  # import repo().Changeset, only: [change_public: 1, change_disabled: 1]

  alias Ecto.Changeset
  alias Bonfire.Classify.Category
  # alias CommonsPub.{Repo}

  @type t :: %__MODULE__{}
  @cast ~w(caretaker_id parent_category_id same_as_category_id)a

  pointable_schema do
    # pointable_schema do

    # field(:id, Pointers.ULID, autogenerate: true)

    # eg. Mamals is a parent of Cat
    belongs_to(:parent_category, Category, type: Pointers.ULID)

    # eg. Olive Oil is the same as Huile d'olive
    belongs_to(:same_as_category, Category, type: Pointers.ULID)

    # which community/collection/organisation/etc this category belongs to, if any
    belongs_to(:caretaker, Pointers.Pointer, type: Pointers.ULID)

    # of course, category is usually a tag
    has_one(:tag, Bonfire.Tag, foreign_key: :id)

    # # Profile and/or character mixins
    # ## to store common fields like name/description
    # has_one(:profile, Bonfire.Data.Social.Profile, foreign_key: :id)
    # ## allows it to be follow-able and federate activities
    # has_one(:character, Bonfire.Data.Identity.Character, foreign_key: :id)

    belongs_to(:creator, @user)

    field(:prefix, :string, virtual: true)
    field(:facet, :string, virtual: true)

    field(:name, :string, virtual: true)
    field(:summary, :string, virtual: true)
    field(:canonical_url, :string, virtual: true)
    field(:preferred_username, :string, virtual: true)

    field(:is_public, :boolean, virtual: true)
    field(:is_disabled, :boolean, virtual: true, default: false)

    field(:published_at, :utc_datetime_usec)
    field(:disabled_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)

    # include fields/relations defined in config (using Flexto)
    flex_schema(:bonfire_classify)
  end

  def create_changeset(nil, attrs) do
    %Category{}
    |> Changeset.cast(%{
      follow_count: %{follower_count: 0, followed_count: 0},
      like_count:   %{liker_count: 0,    liked_count: 0},
    }, [])
    |> Changeset.cast(attrs, @cast)
    |> Changeset.change(
      parent_category_id: parent_category(attrs),
      same_as_category_id: same_as_category(attrs),
      is_public: true
    )
    |> Changeset.cast_assoc(:character, with: &Bonfire.Me.Identity.Characters.changeset/2)
    |> Changeset.cast_assoc(:profile, with: &Bonfire.Me.Social.changeset/2)
    |> Changeset.cast_assoc(:follow_count)
    |> Changeset.cast_assoc(:like_count)
    |> common_changeset()
  end

  def create_changeset(creator, attrs) do
    create_changeset(nil, attrs)
    |> Changeset.change(
      creator_id: Map.get(creator, :id, nil)
    )
  end

  defp parent_category(%{parent_category: id}) when is_binary(id) do
    id
  end

  defp parent_category(%{parent_category: %{id: id}}) when is_binary(id) do
    id
  end

  defp parent_category(_) do
    nil
  end

  defp same_as_category(%{same_as_category: same_as_category}) when is_binary(same_as_category) do
    same_as_category
  end

  defp same_as_category(%{same_as_category: %{id: id}}) when is_binary(id) do
    id
  end

  defp same_as_category(_) do
    nil
  end

  def update_changeset(
        %Category{} = category,
        attrs
      ) do
    category
    |> Changeset.cast(attrs, @cast)
    |> Changeset.change(
      parent_category_id: parent_category(attrs),
      same_as_category_id: same_as_category(attrs)
    )
    |> common_changeset()
  end

  defp common_changeset(changeset) do
    changeset
    # |> Changeset.foreign_key_constraint(:pointer_id, name: :category_pointer_id_fkey)
    # |> change_public()
    # |> change_disabled()
  end

  def context_module, do: Bonfire.Classify.Categories

  def queries_module, do: Bonfire.Classify.Category.Queries

  def follow_filters, do: [:default]
end
