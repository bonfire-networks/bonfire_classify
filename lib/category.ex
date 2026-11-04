# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Classify.Category do
  use Needle.Pointable,
    otp_app: :bonfire_classify,
    source: "category",
    table_id: "2AGSCANBECATEG0RY0RHASHTAG"

  import Untangle
  use Bonfire.Common.E

  @behaviour Bonfire.Common.SchemaModule
  def context_module, do: Bonfire.Classify.Categories
  def query_module, do: Bonfire.Classify.Category.Queries

  def follow_filters, do: [:default]

  # @user Application.compile_env!(:bonfire, :user_schema)

  alias Ecto.Changeset
  alias Bonfire.Classify.Category
  alias Bonfire.Classify.Tree
  alias Bonfire.Common.Utils
  alias Needle.Changesets

  # @type t :: %__MODULE__{}
  @cast ~w(id type)a

  pointable_schema do
    # pointable_schema do
    # field(:id, Needle.UID, autogenerate: true)

    field :type, Ecto.Enum, values: [group: 1, topic: 2, label: 3]

    # materialized path for trees
    has_one(:tree, Tree, foreign_key: :id, on_replace: :update)
    field(:path, EctoMaterializedPath.UIDs, virtual: true)

    # eg. Mamals is a parent of Cat
    # belongs_to(:parent_category, Category, type: Needle.UID)
    #  TODO: just use the parent in Tree without a through assoc?
    has_one :parent_category, through: [:tree, :parent]

    # eg. Olive Oil is the same as Huile d'olive
    # TODO: refactor to reuse Alias mixin
    # belongs_to(:also_known_as, Category, type: Needle.UID)

    # which community/collection/organisation/etc this category belongs to, if any
    # NOTE: using :custodian on Tree instead
    # belongs_to(:caretaker, Needle.Pointer, type: Needle.UID)

    # of course, category can usually be used as a tag
    has_one(:tag, Needle.Pointer, foreign_key: :id)

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

    # field(:deleted_at, :utc_datetime_usec)
    # field(:published_at, :utc_datetime_usec)
    # field(:is_public, :boolean, virtual: true)
    # field(:disabled_at, :utc_datetime_usec)
    # field(:is_disabled, :boolean, virtual: true, default: false)

    # extra data in JSONB (use mixin instead)
    # field(:extra_info, :map)

    # include fields/relations defined in config (using Exto - already included with Pointable)
    # flex_schema(:bonfire_classify)
  end

  def base_create_changeset(attrs, is_local?, creator \\ nil) do
    %Category{}
    |> Changesets.cast(attrs, @cast)
    |> Changeset.change(
      id: e(attrs, :id, nil) || Needle.UID.generate(Category)
      # commented out with the field (never read)
      # is_public: true
    )
    |> common_changeset(attrs, is_local?, creator)
  end

  def create_changeset(creator, attrs, is_local? \\ true)

  def create_changeset(nil, attrs, is_local?) do
    base_create_changeset(attrs, is_local?)
    |> Tree.put_tree(attrs[:custodian], attrs[:parent_category])
    |> debug("cswithtree")
  end

  def create_changeset(creator, attrs, is_local?) do
    base_create_changeset(attrs, is_local?, creator)
    |> Changesets.put_assoc(:created, %{creator_id: Map.get(creator, :id, nil)})
    |> Tree.put_tree(attrs[:custodian] || creator, attrs[:parent_category])
    |> debug("cswithtree")
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

  defp also_known_as(%{also_known_as: also_known_as})
       when is_binary(also_known_as) do
    also_known_as
  end

  defp also_known_as(%{also_known_as: %{id: id}}) when is_binary(id) do
    id
  end

  defp also_known_as(_) do
    nil
  end

  # `user` is who edits it, whose editor's format a new bio is read in
  def update_changeset(
        %Category{} = category,
        attrs,
        is_local? \\ true,
        user \\ nil
      ) do
    # add the mixin IDs for update; also forward top-level :name into the profile mixin
    profile_defaults =
      %{id: category.id}
      |> then(fn p -> if attrs[:name], do: Map.put(p, :name, attrs[:name]), else: p end)

    attrs =
      Map.merge(attrs, %{profile: profile_defaults}, fn _, a, b ->
        Map.merge(a, b)
      end)

    # |> Map.merge(%{character: %{id: category.id}}, fn _, a, b -> Map.merge(a, b) end)

    category
    |> Changesets.cast(attrs, @cast)
    |> common_changeset(attrs, is_local?, user)
  end

  defp common_changeset(
         changeset,
         %{without_character: without_character} = attrs,
         is_local?,
         user
       )
       when without_character in [true, "true"] do
    # debug(attrs)

    changeset
    |> Changeset.cast_assoc(:character,
      #  to allow for non-character labels
      required: false,
      with: &Bonfire.Me.Characters.changeset/2
    )
    |> more_common_changeset(attrs, is_local?, user)
  end

  defp common_changeset(changeset, attrs, true = is_local?, user) do
    # debug(attrs)

    changeset
    |> Changeset.cast_assoc(:character,
      required: true,
      with: &Bonfire.Me.Characters.changeset/2
    )
    |> more_common_changeset(attrs, is_local?, user)
  end

  defp common_changeset(changeset, attrs, false = is_local?, user) do
    changeset
    |> Changeset.cast_assoc(:character,
      required: false,
      with: &Bonfire.Me.Characters.remote_changeset/2
    )
    |> more_common_changeset(attrs, is_local?, user)
  end

  defp more_common_changeset(changeset, _attrs, is_local?, user) do
    changeset
    # |> Changeset.change(
    #  # parent_category_id: parent_category(attrs),
    #  also_known_as_id: also_known_as(attrs)
    # )
    # Ecto's rather than `Needle.Changesets.cast_assoc/3`, which ignores `with:` for a profile it casts anew
    |> Changeset.cast_assoc(:profile, with: profile_changeset_fun(is_local?, user))
    |> Needle.Changesets.cast_assoc(:extra_info,
      with: &Bonfire.Data.Identity.ExtraInfo.changeset/2
    )

    # |> Changeset.foreign_key_constraint(:pointer_id, name: :category_pointer_id_fkey)
    # |> change_public()
    # |> change_disabled()
  end

  # a profile of ours gets a user's checks, and its bio linked in the editing user's format. A mirror's comes from its server, so our length limits, meant for what people type here, don't refuse it, as for a remote user
  defp profile_changeset_fun(true = _is_local?, user),
    do: &Bonfire.Me.Profiles.changeset(&1, &2, local: true, current_user: user)

  defp profile_changeset_fun(_is_local?, _user), do: &Bonfire.Me.Profiles.changeset_simple/2
end
