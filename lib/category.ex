# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Classify.Category do
  use Pointers.Pointable,
    otp_app: :bonfire_classify,
    source: "category",
    table_id: "2AGSCANBECATEG0RY0RHASHTAG"

  import Flexto

  @user Application.compile_env!(:bonfire, :user_schema)

  alias Ecto.Changeset
  alias Bonfire.Classify.Category
  alias Bonfire.Common.Utils
  alias Pointers.Changesets

  @type t :: %__MODULE__{}
  @cast ~w(id parent_category_id same_as_category_id)a

  pointable_schema do
    # pointable_schema do
    # field(:id, Pointers.ULID, autogenerate: true)

    # eg. Mamals is a parent of Cat
    belongs_to(:parent_category, Category, type: Pointers.ULID)

    # eg. Olive Oil is the same as Huile d'olive
    belongs_to(:same_as_category, Category, type: Pointers.ULID)

    # which community/collection/organisation/etc this category belongs to, if any
    # FIXME: use carataker mixin instead?
    # belongs_to(:caretaker, Pointers.Pointer, type: Pointers.ULID)

    # of course, category is usually a tag
    has_one(:tag, Pointers.Pointer, foreign_key: :id)

    # # Profile and/or character mixins
    # ## to store common fields like name/description
    # has_one(:profile, Bonfire.Data.Social.Profile, foreign_key: :id)
    # ## allows it to be follow-able and federate activities
    # has_one(:character, Bonfire.Data.Identity.Character, foreign_key: :id)
    # belongs_to(:creator, @user) # use mixin instead

    field(:name, :string, virtual: true)
    field(:summary, :string, virtual: true)
    field(:canonical_url, :string, virtual: true)
    field(:username, :string, virtual: true)

    field(:is_public, :boolean, virtual: true)
    field(:is_disabled, :boolean, virtual: true, default: false)

    # TODO: remove if unused
    field(:published_at, :utc_datetime_usec)
    field(:disabled_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)

    # extra data in JSONB (use mixin instead)
    # field(:extra_info, :map)

    # include fields/relations defined in config (using Flexto - already included with Pointable)
    # flex_schema(:bonfire_classify)
  end

  def create_changeset(creator, attrs, is_local? \\ true)

  def create_changeset(nil, attrs, is_local?) do
    %Category{}
    |> Changesets.cast(attrs, @cast)
    |> Changeset.change(
      id: Utils.e(attrs, :id, nil) || Pointers.ULID.generate(),
      is_public: true
    )
    |> common_changeset(attrs, is_local?)
  end

  def create_changeset(creator, attrs, is_local?) do
    create_changeset(nil, attrs, is_local?)
    |> Changesets.put_assoc(:created, %{creator_id: Map.get(creator, :id, nil)})
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

  defp same_as_category(%{same_as_category: same_as_category})
       when is_binary(same_as_category) do
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
    # add the mixin IDs for update
    attrs =
      Map.merge(attrs, %{profile: %{id: category.id}}, fn _, a, b ->
        Map.merge(a, b)
      end)

    # |> Map.merge(%{character: %{id: category.id}}, fn _, a, b -> Map.merge(a, b) end)

    category
    |> Changesets.cast(attrs, @cast)
    |> common_changeset(attrs)
  end

  defp common_changeset(changeset, attrs, is_local? \\ true)

  defp common_changeset(changeset, attrs, is_local? = true) do
    changeset
    |> Changesets.cast_assoc(:character,
      with: &Bonfire.Me.Characters.changeset/2
    )
    |> more_common_changeset(attrs)
  end

  defp common_changeset(changeset, attrs, is_local? = false) do
    changeset
    |> Changesets.cast_assoc(:character,
      required: true,
      with: &Bonfire.Me.Characters.remote_changeset/2
    )
    |> more_common_changeset(attrs)
  end

  defp more_common_changeset(changeset, attrs) do
    changeset
    |> Changeset.change(
      parent_category_id: parent_category(attrs),
      same_as_category_id: same_as_category(attrs)
    )
    |> Changesets.cast_assoc(:profile, with: &Bonfire.Me.Profiles.changeset/2)

    # |> Changeset.foreign_key_constraint(:pointer_id, name: :category_pointer_id_fkey)
    # |> change_public()
    # |> change_disabled()
  end

  @behaviour Bonfire.Common.SchemaModule
  def context_module, do: Bonfire.Classify.Categories
  def query_module, do: Bonfire.Classify.Category.Queries

  def follow_filters, do: [:default]
end
