defmodule Bonfire.Classify.Categories do
  import Where
  alias Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]
  use Utils, only: [maybe_get: 2, maybe_get: 3, is_ulid?: 1]

  alias Bonfire.Classify.Category
  alias Bonfire.Classify.Category.Queries

  alias Bonfire.Me.Characters

  @facet_name "Category"
  @federation_type "Group"

  def federation_module, do: @federation_type # FIXME, once permissioned groups are implemented Category should only match permission-less groups

  # queries

  def one(filters), do: repo().single(Queries.query(Category, filters))

  def get(id) do
    if is_ulid?(id) do
      one([:default, id: id])
    else
      one([:default, username: id])
    end
  end

  def by_username(u), do: get(u)

  def many(filters \\ []), do: {:ok, repo().many(Queries.query(Category, filters))}
  def list(), do: many([:default])


  ## mutations

  @doc """
  Create a brand-new category object, with info stored in profile and character mixins
  """
  def create(creator, attrs, is_local? \\ true)

  def create(creator, %{category: %{} = cat_attrs} = params, is_local?) do
    create(
      creator,
      params
      |> Map.merge(cat_attrs)
      |> Map.delete(:category),
      is_local?
    )
  end

  def create(creator, %{facet: facet} = params, is_local?) when not is_nil(facet) do
    with attrs <- attrs_prepare(params, is_local?) do
      do_create(creator, attrs, is_local?)
    end
  end

  def create(creator, params, is_local?) do
    create(creator, Map.put(params, :facet, @facet_name), is_local?)
  end


  defp do_create(creator, attrs, is_local? \\ true) do
    # TODO: check that the category doesn't already exist (same name and parent)

    repo().transact_with(fn ->

      with {:ok, category} <- insert_category(creator, attrs, is_local?)do

        Utils.maybe_apply(Bonfire.Social.Objects, :publish, [creator, :create, category, attrs, __MODULE__])
        # add to search index
        maybe_index(category)

        {:ok, category}
      end
    end)
  end

  def create_remote(attrs) do
    # use canonical username for character
    create(nil, attrs, false)
  end


  defp attrs_prepare(attrs, is_local? \\ true) do
    attrs = attrs
    |> attrs_with_parent_category()

    attrs = attrs
    |> Map.put(:profile, Map.merge(attrs, Map.get(attrs, :profile, %{})))
    |> Map.put(:character, Map.merge(attrs, Map.get(attrs, :character, %{})))

    if(is_local?) do
      attrs
      |> attrs_with_username()
    else
      attrs
    end
  end


  def attrs_with_parent_category(%{parent_category: %{id: id} = parent_category} = attrs)
      when not is_nil(id) do
        with {:ok, loaded_parent} <- get(id) do
      put_attrs_with_parent_category(attrs, Map.merge(parent_category, loaded_parent))
    else
      e ->
        debug(attrs_with_parent_category: e)
        put_attrs_with_parent_category(attrs, nil)
    end
  end

  def attrs_with_parent_category(%{parent_category: id} = attrs)
      when is_binary(id) and id != "" do
    with {:ok, parent_category} <- get(id) do
      put_attrs_with_parent_category(attrs, parent_category)
    else
      _ ->
        put_attrs_with_parent_category(attrs, nil)
    end
  end

  def attrs_with_parent_category(%{parent_category_id: id} = attrs) when not is_nil(id) do
    attrs_with_parent_category(Map.put(attrs, :parent_category, id))
  end

  def attrs_with_parent_category(attrs) do
    put_attrs_with_parent_category(attrs, nil)
  end

  def put_attrs_with_parent_category(attrs, nil) do
    attrs
    |> Map.put(:parent_category, nil)
    |> Map.put(:parent_category_id, nil)
  end

  def put_attrs_with_parent_category(attrs, %{id: id} = parent_category) do

    attrs
    |> Map.put(:parent_category, parent_category)
    |> Map.put(:parent_category_id, id)
  end

  # todo: improve

  def attrs_with_username(
        %{character: %{username: preferred_username}} = attrs
      )
      when not is_nil(preferred_username) and preferred_username != "" do
    put_generated_username(attrs, preferred_username)
  end

  def attrs_with_username(%{profile: %{name: name}} = attrs) do
    put_generated_username(attrs, name)
  end

  def attrs_with_username(attrs) do
    attrs
  end

  def username_with_parent(
        %{parent_category: %{username: parent_name}},
        name
      )
      when not is_nil(name) and not is_nil(parent_name) do
    name <> "-" <> parent_name
  end

  def username_with_parent(
        %{parent_category: %{character: %{username: parent_name}}},
        name
      )
      when not is_nil(name) and not is_nil(parent_name) do
    name <> "-" <> parent_name
  end

  def username_with_parent(
        %{parent_category: %{profile: %{name: parent_name}}},
        name
      )
      when not is_nil(name) and not is_nil(parent_name) do
    name <> "-" <> parent_name
  end

  def username_with_parent(
        %{parent_category: %{name: parent_name}},
        name
      )
      when not is_nil(name) and not is_nil(parent_name) do
    name <> "-" <> parent_name
  end

  def username_with_parent(
        %{parent_tag: %{name: parent_name}},
        name
      )
      when not is_nil(name) and not is_nil(parent_name) do
    name <> "-" <> parent_name
  end

  def username_with_parent(_, name) do
    name
  end

  def put_generated_username(attrs, username) do

    attrs |> Map.put(:character, Map.merge(Map.get(attrs, :character, %{}), %{username: try_several_usernames(attrs, username, username)}))
  end

  def try_several_usernames(attrs, original_username, try_username, attempt \\ 1) do
    try_username = clean_username(try_username)

    if Bonfire.Me.Characters.username_available?(try_username) do
      try_username
    else

      bigger_username = username_with_parent(attrs, original_username) |> clean_username()

      try_username = if attempt > 1, do: bigger_username<>"#{attempt+1}", else: bigger_username

      if attempt < 20 do
        try_several_usernames(attrs, bigger_username, try_username, attempt+1)
      else
        error("username taken")
        nil
      end
    end
  end

  def clean_username(input) do
    Bonfire.Common.Text.underscore_truncate(input, 61)  |> Bonfire.Me.Characters.clean_username
  end

  def name_already_taken?(%Ecto.Changeset{} = changeset) do
    #debug(changeset)
    cs = Map.get(changeset.changes, :character, changeset)
    case cs.errors[:username] do
      {"has already been taken", _} -> true
      _ -> false
    end
  end

  defp attrs_mixins_with_id(attrs, category) do
    Map.put(attrs, :id, category.id)
  end

  defp insert_category(user, attrs, is_local?) do
    #debug(inserting_category: attrs)
    cs = Category.create_changeset(user, attrs, is_local?)
    |> debug()
    with {:ok, category} <- repo().insert(cs) do
      {:ok, category}
    end
  end

  def update(user \\ nil, category, attrs)

  def update(user, %Category{} = category, %{category: %{} = cat_attrs} = attrs) do
    update(
      user,
      category,
      attrs
      |> Map.merge(cat_attrs)
      |> Map.delete(:category)
    )
  end

  def update(user, %Category{} = category, attrs) do
    category = repo().preload(category, [:profile, character: [:actor]])

    attrs = Utils.input_to_atoms(attrs)
    #debug(category)
    # debug(update: attrs)

    repo().transact_with(fn ->
      with {:ok, category} <- repo().update(Category.update_changeset(category, attrs)) do
        {:ok, category}
      end
    end)
  end

  def update_local_actor(%Category{} = cat, params) do
    with {:ok, cat} <- update(nil, cat, params),
         actor <- format_actor(cat) do
      {:ok, actor}
    end
  end

  def update_local_actor(actor, params) do
    with {:ok, cat} <- get(actor.pointer_id) do
      update_local_actor(cat, params)
    end
  end


  def format_actor(cat) do
    Bonfire.Federate.ActivityPub.Utils.format_actor(cat, @federation_type)
  end

  def indexing_object_format(%{id: _} = obj) do

    obj = Bonfire.Common.Repo.maybe_preload(obj, [:profile, :character, :tag, :parent_category], false) #|> IO.inspect

    %{
      "index_type" => Utils.e(obj, :facet, "Category"),
      "prefix"=> Utils.e(obj, :prefix, nil) || Utils.e(obj, :tag, :prefix, "+"),
      "id" => obj.id,
      "parent" => indexing_object_format_parent(Map.get(obj, :parent_category)),
      "profile" => Bonfire.Me.Profiles.indexing_object_format(obj.profile),
      "character" => Bonfire.Me.Characters.indexing_object_format(obj.character),
    }
    # |> IO.inspect
  end

  def indexing_object_format(_), do: nil

  def indexing_object_format_parent(%{id: _} = obj) do

    obj = Bonfire.Common.Repo.maybe_preload(obj, [:profile, :parent_category], false) #|> IO.inspect

    %{
      "id" => obj.id,
      "parent" => indexing_object_format_parent(Map.get(obj, :parent_category)),
      "name" => indexing_object_format_name(obj),
    } #|> IO.inspect
  end
  def indexing_object_format_parent(_), do: nil

  def indexing_object_format_name(object) do
     object.profile.name
  end

  def maybe_index(obj) do
    object = indexing_object_format(obj)

    if module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_index_object(object)
    else
      :ok
    end
  end


  def soft_delete(%Category{} = c) do
    repo().transact_with(fn ->
      with {:ok, c} <- Bonfire.Common.Repo.Delete.soft_delete(c) do
        {:ok, c}
      else
        e ->
          {:error, e}
      end
    end)
  end

  def soft_delete(id) when is_binary(id) do
    with {:ok, c} <- get(id) do
      soft_delete(c)
    end
  end

end
