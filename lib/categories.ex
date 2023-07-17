defmodule Bonfire.Classify.Categories do
  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  use Bonfire.Boundaries.Queries
  import Bonfire.Classify

  alias Bonfire.Classify
  alias Bonfire.Classify.Category
  alias Bonfire.Classify.Tree
  alias Bonfire.Classify.Category.Queries

  alias Bonfire.Me.Characters

  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Bonfire.Classify.Category
  def query_module, do: Bonfire.Classify.Category.Queries

  @facet_name "Category"
  @federation_type "Group"

  # FIXME, once permissioned groups are implemented Category should only match permission-less groups
  def federation_module, do: @federation_type

  # queries

  def one(filters, opts \\ []) do
    Queries.query(Category, filters)
    |> boundarise(category.id, opts ++ [verbs: [:read]])
    |> proload([:settings])
    |> repo().single()
  end

  def get(id, filters_and_or_opts \\ [:default]) do
    # FIXME: do not mix filters and opts
    if is_ulid?(id) do
      one(filters_and_or_opts ++ [id: id], filters_and_or_opts)
    else
      one(filters_and_or_opts ++ [username: id], filters_and_or_opts)
    end
  end

  def by_username(u, opts \\ []), do: one([username: u], opts)

  def list(filters \\ [:default], opts \\ [])

  def list(q, opts) when is_struct(q) do
    q
    |> boundarise(category.id, opts ++ [verbs: [:see]])
    |> repo().many_paginated(opts)
  end

  def list(filters, opts) do
    Category
    |> Queries.query(filters)
    |> list(opts)
  end

  def list_tree(filters \\ [:default, tree_max_depth: 2], opts \\ [limit: 100]) do
    # Queries.query_tree(Tree, filters)
    Category
    |> Queries.query(filters)
    |> debug
    |> list(opts)
  end

  def moderators(category),
    do: Bonfire.Boundaries.Controlleds.list_subjects_by_verb(category, :mediate)

  # TODO: default to creator otherwise?
  # |> debug("modddds")

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

  def create(creator, %{facet: facet} = params, is_local?)
      when not is_nil(facet) do
    with attrs <- attrs_prepare(creator, params, is_local?) do
      do_create(creator, attrs, is_local?)
    end
  end

  def create(creator, params, is_local?) do
    create(creator, Map.put(params, :facet, @facet_name), is_local?)
  end

  defp do_create(creator, attrs, is_local? \\ true) do
    # TODO: check that the category doesn't already exist (same name and parent)
    # debug(is_local?)

    cs = Category.create_changeset(creator, attrs, is_local?)

    repo().transact_with(fn ->
      with {:ok, category} <- repo().insert(cs) do
        # set ACLs and federate
        publish(
          creator,
          :define,
          category,
          [boundaries_caretaker: category, attrs: attrs],
          __MODULE__
        )

        # maybe publish subcategory creation to parent category's outbox
        if module_enabled?(Bonfire.Social.Tags, creator),
          do:
            Bonfire.Social.Tags.maybe_auto_boost(
              creator,
              Utils.e(category, :parent_category, nil) ||
                Utils.e(category, :tree, :parent, nil) ||
                Utils.e(category, :tree, :parent_id, nil),
              category
            )

        if is_local? do
          if attrs[:without_character] not in [true, "true"],
            do:
              Utils.maybe_apply(Bonfire.Social.Follows, :follow, [
                creator,
                category,
                skip_boundary_check: true
              ])

          # add to my own to favourites by default
          Utils.maybe_apply(Bonfire.Social.Likes, :do_like, [
            creator,
            category,
            skip_boundary_check: true
          ])
        end

        # add to search index
        maybe_index(indexing_object_format(category))

        {:ok, category}
      end
    end)
  end

  def create_remote(attrs) do
    # use canonical username for character
    create(nil, attrs, false)
  end

  defp attrs_prepare(creator, attrs, is_local? \\ true)

  defp attrs_prepare(creator, %{without_character: without_character} = attrs, _is_local?)
       when without_character in [true, "true"] do
    attrs_prepare_tree(creator, attrs)
    |> Map.put_new_lazy(:id, &Pointers.ULID.generate/0)
    |> Map.put(:profile, Map.merge(attrs, Map.get(attrs, :profile, %{})))
  end

  defp attrs_prepare(creator, attrs, is_local?) do
    attrs =
      attrs_prepare_tree(creator, attrs)
      |> Map.put_new_lazy(:id, &Pointers.ULID.generate/0)
      |> Map.put(:profile, Map.merge(attrs, Map.get(attrs, :profile, %{})))
      |> Map.put(:character, Map.merge(attrs, Map.get(attrs, :character, %{})))

    if(is_local?) do
      attrs_with_username(attrs)
    else
      attrs
    end
  end

  def attrs_prepare_tree(
        creator,
        %{parent_category: %Pointers.Pointer{id: id} = parent_category} = attrs
      ) do
    with {:ok, loaded_parent} <- get(id, preload: :tree, current_user: creator, verb: :create) do
      put_attrs_with_parent_category(
        attrs,
        Map.merge(parent_category, loaded_parent)
      )
    else
      e ->
        error(e)
        put_attrs_with_parent_category(attrs, nil)
    end
  end

  def attrs_prepare_tree(_creator, %{parent_category: %{id: _id} = parent_category} = attrs) do
    put_attrs_with_parent_category(
      attrs,
      parent_category
    )
  end

  def attrs_prepare_tree(creator, %{parent_category: id} = attrs)
      when not is_nil(id) do
    with {:ok, parent_category} <- get(id, preload: :tree, current_user: creator, verb: :create) do
      put_attrs_with_parent_category(attrs, parent_category)
    else
      _ ->
        put_attrs_with_parent_category(attrs, nil)
    end
  end

  def attrs_prepare_tree(creator, %{parent_category_id: id} = attrs)
      when not is_nil(id) do
    attrs_prepare_tree(creator, Map.put(attrs, :parent_category, id))
  end

  def attrs_prepare_tree(_creator, attrs) do
    put_attrs_with_parent_category(attrs, nil)
  end

  def put_attrs_with_parent_category(attrs, %{id: id} = parent_category) do
    attrs
    |> Map.put(:parent_category, parent_category)

    # |> Map.put(:parent_category_id, id)
  end

  def put_attrs_with_parent_category(attrs, _) do
    attrs
    |> Map.put(:parent_category, nil)

    # |> Map.put(:parent_category_id, nil)
  end

  # todo: improve

  def attrs_with_username(%{character: %{username: preferred_username}} = attrs)
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
    Map.put(
      attrs,
      :character,
      Map.merge(Map.get(attrs, :character, %{}), %{
        username: try_several_usernames(attrs, username, username)
      })
    )
  end

  def try_several_usernames(
        attrs,
        original_username,
        try_username,
        attempt \\ 1
      ) do
    try_username = clean_username(try_username)

    if Bonfire.Me.Characters.username_available?(try_username) do
      try_username
    else
      bigger_username = username_with_parent(attrs, original_username) |> clean_username()

      try_username =
        if attempt > 1,
          do: bigger_username <> "#{attempt + 1}",
          else: bigger_username

      if attempt < 20 do
        try_several_usernames(attrs, bigger_username, try_username, attempt + 1)
      else
        error("username taken")
        nil
      end
    end
  end

  def clean_username(input) do
    Bonfire.Common.Text.underscore_truncate(input, 61)
    |> Bonfire.Me.Characters.clean_username()
  end

  def name_already_taken?(%Ecto.Changeset{} = changeset) do
    # debug(changeset)
    cs = Map.get(changeset.changes, :character, changeset)

    case cs.errors[:username] do
      {"has already been taken", _} -> true
      _ -> false
    end
  end

  defp attrs_mixins_with_id(attrs, category) do
    Map.put(attrs, :id, category.id)
  end

  def update(user \\ nil, category, attrs)

  def update(user, %Category{} = category, %{category: %{} = cat_attrs} = attrs) do
    __MODULE__.update(
      user,
      category,
      attrs
      |> Map.merge(cat_attrs)
      |> Map.delete(:category)
    )
  end

  def update(user, %Category{} = category, attrs) do
    if Classify.ensure_update_allowed(user, category) do
      category = repo().preload(category, [:profile, character: [:actor]])

      attrs = Enums.input_to_atoms(attrs)

      # debug(category)
      # debug(update: attrs)

      repo().transact_with(fn ->
        with {:ok, category} <-
               repo().update(Category.update_changeset(category, attrs)) do
          # update search index
          maybe_index(indexing_object_format(category))

          {:ok, category}
        end
      end)
    else
      error(category, "Sorry, you cannot edit this.")
    end
  end

  def soft_delete(%Category{} = c, user) do
    if Classify.ensure_update_allowed(user, c) do
      maybe_unindex(c)

      repo().transact_with(fn ->
        with {:ok, c} <- Bonfire.Common.Repo.Delete.soft_delete(c) do
          {:ok, c}
        else
          e ->
            {:error, e}
        end
      end)
    else
      error("Sorry, you cannot archive this.")
    end
  end

  def soft_delete(id, user) when is_binary(id) do
    with {:ok, c} <- get(id, current_user: user, verb: :delete) do
      soft_delete(c, user)
    end
  end

  def update_local_actor(%Category{} = cat, params) do
    with {:ok, cat} <- __MODULE__.update(nil, cat, params),
         actor <- format_actor(cat) do
      {:ok, actor}
    end
  end

  def update_local_actor(actor, params) do
    with {:ok, cat} <- get(actor.pointer_id, skip_boundary_check: true) do
      update_local_actor(cat, params)
    end
  end

  def format_actor(cat) do
    Bonfire.Federate.ActivityPub.AdapterUtils.format_actor(cat, @federation_type)
  end

  # TODO: other verbs like update
  def ap_publish_activity(subject, _verb, category) do
    category = repo().preload(category, [:character, :profile])

    with {:ok, subject_actor} <- ActivityPub.Actor.get_cached(pointer: subject) do
      # debug(message.activity.tags)

      recipients =
        [
          e(category, :parent_category, nil) || e(category, :tree, :parent, nil),
          e(category, :also_known_as, nil) || category.also_known_as_id
        ]
        |> Enums.filter_empty([])
        |> Enum.map(fn id ->
          with %{ap_id: ap_id} <- ActivityPub.Actor.get_cached!(pointer: id) do
            ap_id
          else
            e ->
              warn(e, "Actor not found for parent or related category #{id}")
              nil
          end
        end)
        |> Enums.filter_empty([])

      attrs = %{
        actor: subject_actor,
        # parent category
        context: List.first(recipients),
        object: format_actor(category),
        to: recipients,
        pointer: Types.ulid(category)
      }

      ActivityPub.create(attrs)
    else
      e ->
        error(e, "Subject actor not found")
    end
  end

  def ap_receive_activity(creator, activity, object) do
    attrs = %{
      # TODO: boundaries
      to_circles: "public",
      # TODO: map the fields
      category: object.data
    }

    create(creator, attrs, false)
  end

  def indexing_object_format(%{id: _} = obj) do
    # |> IO.inspect
    obj =
      repo().maybe_preload(
        obj,
        [:profile, :character, :tag, :parent_category],
        false
      )

    %{
      "index_type" => Utils.e(obj, :facet, "Category"),
      "prefix" => Utils.e(obj, :prefix, nil) || Utils.e(obj, :tag, :prefix, "+"),
      "id" => obj.id,
      "parent" => indexing_object_format_parent(Map.get(obj, :parent_category)),
      "profile" => Bonfire.Me.Profiles.indexing_object_format(obj.profile),
      "character" => Bonfire.Me.Characters.indexing_object_format(obj.character)
    }

    # |> IO.inspect
  end

  def indexing_object_format(_), do: nil

  def indexing_object_format_parent(%{id: _} = obj) do
    # |> IO.inspect
    obj =
      repo().maybe_preload(
        obj,
        [:profile, :parent_category],
        false
      )

    %{
      "id" => obj.id,
      "parent" => indexing_object_format_parent(Map.get(obj, :parent_category)),
      "name" => indexing_object_format_name(obj)
    }

    # |> IO.inspect
  end

  def indexing_object_format_parent(_), do: nil

  def indexing_object_format_name(object) do
    object.profile.name
  end
end
