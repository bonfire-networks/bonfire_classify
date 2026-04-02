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

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      @federation_type,
      :group
    ]

  # queries

  def one(filters, opts \\ []) do
    Queries.query(Category, filters)
    |> boundarise(category.id, opts ++ [verbs: [:read]])
    |> proload([:settings])
    |> repo().single()
  end

  def get(id, filters_and_or_opts \\ [:default]) do
    # FIXME: do not mix filters and opts
    if is_uid?(id) do
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
    |> debug()
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

  def create(creator, %{category: %{} = attrs} = params, is_local?) do
    create(
      creator,
      params
      |> Map.merge(attrs)
      |> Map.delete(:category),
      is_local?
    )
  end

  def create(creator, %{facet: facet} = params, is_local?)
      when not is_nil(facet) do
    with attrs <- attrs_prepare(creator, params, is_local?) |> info("attrs prepared") do
      do_create(creator, attrs, is_local?)
    end
  end

  def create(creator, params, is_local?) do
    create(creator, Enum.into(params, %{facet: @facet_name}), is_local?)
  end

  def create_remote(attrs, _opts \\ []) do
    warn(attrs, "WIP")
    # use canonical username for character
    create(nil, attrs, false)
  end

  defp do_create(creator, attrs, is_local? \\ true) do
    # TODO: check that the category doesn't already exist (same name and parent)
    # debug(is_local?)

    cs =
      Category.create_changeset(creator, attrs, is_local?)
      |> debug()

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
        Utils.maybe_apply(
          Bonfire.Social.Tags,
          :maybe_auto_boost,
          [
            creator,
            e(category, :parent_category, nil) ||
              e(category, :tree, :parent, nil) ||
              e(category, :tree, :parent_id, nil),
            category
          ],
          current_user: creator
        )

        if e(attrs, :type, nil) == :group do
          # create members circle and add creator as first member
          Bonfire.Boundaries.Scaffold.Groups.create_default_boundaries(category, creator)
        end

        if is_local? && creator do
          if attrs[:without_character] not in [true, "true"],
            do:
              Utils.maybe_apply(
                Bonfire.Social.Graph.Follows,
                :follow,
                [
                  creator,
                  category,
                  skip_boundary_check: true
                ],
                current_user: creator
              )

          # add to my own to bookmarls by default
          Utils.maybe_apply(
            Bonfire.Social.Bookmarks,
            :bookmark,
            [
              creator,
              category,
              skip_boundary_check: true
            ],
            current_user: creator
          )

          # make creator the caretaker
          Utils.maybe_apply(Bonfire.Boundaries.Controlleds, :grant_role, [
            creator,
            category,
            :administer,
            [current_user: creator, scope: category]
          ])
        end

        # add to search index
        maybe_apply(Bonfire.Search, :maybe_index, [category, nil, creator], creator)

        {:ok, category}
      end
    end)
  end

  defp attrs_prepare(creator, attrs, is_local? \\ true)

  defp attrs_prepare(creator, %{without_character: without_character} = attrs, _is_local?)
       when without_character in [true, "true"] do
    attrs_prepare_tree(creator, attrs)
    |> Map.put_new_lazy(:id, &Needle.UID.generate/0)
    |> Map.put(:profile, Map.merge(attrs, Map.get(attrs, :profile, %{})))
  end

  defp attrs_prepare(creator, attrs, is_local?) do
    debug(attrs)

    attrs =
      attrs
      |> Map.put_new_lazy(:id, &Needle.UID.generate/0)
      |> Map.put(:profile, Map.merge(attrs, Map.get(attrs, :profile, %{})))
      |> Map.put(:character, Map.merge(attrs, Map.get(attrs, :character, %{})))
      |> attrs_prepare_tree(creator, ...)

    if(is_local?) do
      attrs_with_username(attrs)
    else
      attrs
    end
  end

  def attrs_prepare_tree(
        creator,
        %{parent_category: %Needle.Pointer{id: id} = parent_category} = attrs
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

  ## Group membership functions

  @doc "Returns (or creates) the members circle for a group."
  def members_circle(group) do
    Bonfire.Boundaries.Scaffold.Groups.members_circle(group)
  end

  @doc """
  Batch-checks which of the given group IDs the subject is a member of (via the members circle).
  Returns a map of `%{group_id => true}`. Single query.
  """
  def member_of_groups?(subject, group_ids) when is_list(group_ids),
    do:
      Bonfire.Boundaries.Circles.encircled_by_objects_stereoptypes?(
        subject,
        group_ids,
        :group_members
      )

  @doc """
  Join a group. Follows the group (for feed updates) and, if permitted, adds the user
  to the members circle. If the group requires approval (`:no_follow` ACL), a join request
  is created instead.
  """
  def join_group(current_user, group_or_id, opts \\ []) do
    with {:ok, group} <- maybe_fetch(group_or_id),
         {:ok, circle} <- members_circle(group) do
      case Bonfire.Social.Graph.Follows.follow(current_user, group, opts) do
        {:ok, %Bonfire.Data.Social.Follow{}} ->
          Bonfire.Boundaries.Circles.add_to_circles(current_user, circle)
          {:ok, %{member: true, requested: false}}

        {:ok, _request} ->
          # :no_follow ACL triggered a follow request — don't add to circle yet
          {:ok, %{member: false, requested: true}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Accept a pending join request for a group. Wraps `Follows.accept/1` and adds the
  requester to the group's members circle.
  """
  def accept_join_request(admin_or_group, request_or_id, opts \\ []) do
    with {:ok, follow} <-
           Bonfire.Social.Graph.Follows.accept(request_or_id, opts),
         requester = e(follow, :edge, :subject, nil),
         group = e(follow, :edge, :object, nil),
         {:ok, circle} <- members_circle(group) do
      Bonfire.Boundaries.Circles.add_to_circles(requester, circle)
      {:ok, %{member: true, requested: false}}
    end
  end

  @doc "Leave a group, unfollowing and removing from the members circle."
  def leave_and_unfollow_group(current_user, group_or_id, opts \\ []) do
    with {:ok, group} <- leave_group(current_user, group_or_id, opts),
         {:ok, _} <- Bonfire.Social.Graph.Follows.unfollow(current_user, group_or_id, opts) do
      {:ok, %{member: false, requested: false, following: false}}
    end
  end

  @doc "Leave a group, unfollowing and removing from the members circle."
  def leave_group(current_user, group_or_id, opts \\ [])

  def leave_group(current_user, id, opts) when is_binary(id) do
    with {:ok, group} <- maybe_fetch(id) do
      leave_group(current_user, group, opts)
    end
  end

  def leave_group(current_user, group, opts) do
    with {:ok, circle} <- members_circle(group) do
      Bonfire.Boundaries.Circles.remove_from_circles(current_user, [circle])
      {:ok, %{member: false, requested: false}}
    end
  end

  @doc "Returns true if the user is a member of the group (in the members circle)."
  def member?(current_user, group) do
    case members_circle(group) do
      {:ok, circle} ->
        Bonfire.Boundaries.Circles.is_encircled_by?(current_user, circle)

      _ ->
        Bonfire.Social.Graph.Follows.following?(current_user, group)
    end
  end

  @doc """
  Returns the membership role of the user in the group:
  `"admin"`, `"moderator"`, `"member"`, or `nil`.
  """
  def member_role(current_user, group) do
    cond do
      e(group, :tree, :custodian_id, nil) == Enums.id(current_user) ->
        "admin"

      Bonfire.Boundaries.can?(current_user, :mediate, group) ->
        "moderator"

      member?(current_user, group) ->
        "member"

      true ->
        nil
    end
  end

  @doc """
  Derives the join mode from the group's boundary preset.
  Returns `"free"`, `"request"`, or `"invite"`.
  """
  def join_mode(preset_boundary) when is_binary(preset_boundary) do
    case preset_boundary do
      "open" -> "free"
      "visible" -> "request"
      "private" -> "invite"
      _ -> "free"
    end
  end

  def join_mode(group) do
    case Bonfire.Boundaries.preset_boundary_from_acl(group, Bonfire.Classify.Category) do
      preset_boundary when is_binary(preset_boundary) -> join_mode(preset_boundary)
      _ -> "free"
    end
  end

  @doc "Returns the member count for a group via its members circle, or follower count for topics."
  def members_count(group) do
    type = e(group, :type, nil)

    if is_nil(type) or type == :group do
      case members_circle(group) do
        {:ok, circle} -> Bonfire.Boundaries.Circles.count_members(circle)
        _ -> e(group, :character, :follow_count, :object_count, 0)
      end
    else
      e(group, :character, :follow_count, :object_count, 0)
    end
  end

  @doc "Lists members of a group (via members circle) or topic (via followers)."
  def list_members(group_or_topic, opts \\ []) do
    if e(group_or_topic, :type, nil) == :group do
      case members_circle(group_or_topic) do
        {:ok, circle} -> Bonfire.Boundaries.Circles.list_members(circle, opts)
        _ -> []
      end
    else
      Bonfire.Social.Graph.Follows.list_followers(group_or_topic, opts)
    end
  end

  defp maybe_fetch(%{id: _} = group), do: {:ok, group}
  defp maybe_fetch(id) when is_binary(id), do: get(id)

  def update(user \\ nil, category, attrs, is_local? \\ true)

  def update(user, %Category{} = category, %{category: %{} = cat_attrs} = attrs, is_local?) do
    __MODULE__.update(
      user,
      category,
      attrs
      |> Map.merge(cat_attrs)
      |> Map.delete(:category),
      is_local?
    )
  end

  def update(user, %Category{} = category, attrs, is_local?) do
    if Classify.ensure_update_allowed(user, category) do
      category = repo().preload(category, [:profile, character: [:actor]])

      attrs = Enums.input_to_atoms(attrs)

      # debug(category)
      # debug(update: attrs)

      repo().transact_with(fn ->
        with {:ok, category} <-
               repo().update(Category.update_changeset(category, attrs, is_local?)) do
          # update search index

          maybe_apply(Bonfire.Search, :maybe_index, [category, nil, user], user)

          {:ok, category}
        else
          e ->
            error(e, "Could not update")
        end
      end)
    else
      error(category, "Sorry, you cannot edit this.")
    end
  end

  def soft_delete(%Category{} = c, user) do
    if Classify.ensure_update_allowed(user, c) do
      maybe_apply(Bonfire.Search, :maybe_unindex, [c])

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
    with {:ok, cat} <- __MODULE__.update(:skip_boundary_check, cat, params, true),
         actor <- format_actor(cat) do
      {:ok, actor}
    end
  end

  def update_local_actor(%{pointer_id: pointer_id}, params) do
    with {:ok, cat} <- get(pointer_id, skip_boundary_check: true) do
      update_local_actor(cat, params)
    end
  end

  def update_remote_actor(%Category{} = cat, params) do
    with {:ok, cat} <- __MODULE__.update(:skip_boundary_check, cat, params, false),
         actor <- format_actor(cat) do
      {:ok, actor}
    end
  end

  def update_remote_actor(%{pointer_id: pointer_id}, params) do
    with {:ok, cat} <- get(pointer_id, skip_boundary_check: true) do
      update_remote_actor(cat, params)
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
          # || category.also_known_as_id
          e(category, :also_known_as, nil)
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
        pointer: Types.uid(category)
      }

      ActivityPub.create(attrs)
    else
      e ->
        error(e, "Subject actor not found")
    end
  end

  def ap_receive_activity(creator, _activity, object) do
    attrs = %{
      # TODO: boundaries
      boundary: "public_remote",
      # to_circles: "public",
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
        [:profile, :tag, :parent_category, character: [:peered]],
        false
      )

    %{
      "id" => obj.id,
      "index_type" => e(obj, :facet, nil) || Types.module_to_str(Category),
      "prefix" => e(obj, :prefix, nil) || e(obj, :tag, :prefix, "+"),
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
      "index_type" => e(obj, :facet, nil) || Types.module_to_str(Category),
      "parent" => indexing_object_format_parent(Map.get(obj, :parent_category)),
      "name" => indexing_object_format_name(obj)
    }

    # |> IO.inspect
  end

  def indexing_object_format_parent(_), do: nil

  def indexing_object_format_name(object), do: e(object, :profile, :name, nil)
end
