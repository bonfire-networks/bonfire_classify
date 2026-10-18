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
      :group,
      # a change to who moderates a community, routed to us by the collection its `attributedTo`
      # names (see `ap_receive_activity/3` below)
      {"Add", "attributedTo"},
      {"Remove", "attributedTo"},
      # owns the `moderators` collection our own `attributedTo` points at, served via collection_items/collection_total
      {:collection, "moderators"},
      # and the `members` one our actor declares, which is what tells a remote server that joining here is not following
      {:collection, "members"},
      # Membership of a group, which is not the same question as following one. Claimed as `{activity, "Group"}` because ingest tries that pair BEFORE the activity type alone, so these win for a Group object while `Bonfire.Social.Graph.Follows`' plain `"Follow"` keeps handling follows of everyone else.
      {"Follow", @federation_type},
      {"Join", @federation_type},
      {"Leave", @federation_type},
      # a remote group answering a local person's `Join`, claimed by the answered activity's type the way `Follows` claims `{"Accept", "Follow"}`
      {"Accept", "Join"},
      {"Reject", "Join"}
    ]

  @doc """
  Items of a group's `moderators` collection, which is what `attributedTo` points at. 1b12 receivers accept moderation when the actor is mod-listed, so this is what lets our moderators act for the group from their own instances.

  And of its `members` collection, paged by the `limit` and `offset` opts. Every group declares that one, so its members are only listed when the group's visibility shows them, and otherwise it's served empty.
  """
  def collection_items(collection, opts \\ []) do
    # POINTER IDS, not URLs: `Adapter.shape_members/2` turns them into whatever the caller asked for (`:ap_ids`, `:pointers`, `:ap_objects`), preloading each member's locality assocs at source so `canonical_url/1` does not trip the preload guard per member
    case ActivityPub.Utils.parse_collection_ap_id(e(collection, :data, "id", nil)) do
      {:ok, "members", group_id} ->
        case members_shown_circle(group_id) do
          %{} = circle ->
            from(e in Bonfire.Data.AccessControl.Encircle,
              where: e.circle_id == ^uid(circle),
              order_by: e.subject_id,
              select: e.subject_id,
              limit: ^(opts[:limit] || 100),
              offset: ^(opts[:offset] || 0)
            )
            |> repo().all()

          _ ->
            []
        end

      {:ok, _moderators, group_id} ->
        moderators(group_id)

      _ ->
        []
    end
  end

  @doc "`totalItems` for a group's `moderators` or `members` collection."
  def collection_total(collection, opts \\ []) do
    case ActivityPub.Utils.parse_collection_ap_id(e(collection, :data, "id", nil)) do
      {:ok, "members", group_id} ->
        case members_shown_circle(group_id) do
          %{} = circle -> Bonfire.Boundaries.Circles.count_members(circle)
          _ -> 0
        end

      _ ->
        collection_items(collection, opts) |> length()
    end
  end

  # the members circle, only when the group's visibility shows its members: the rule `AdapterUtils.moderators_collection_ap_id/2` applies to moderators. Looked up rather than created, since serving a collection is a read
  defp members_shown_circle(group_id) do
    visibility = Bonfire.Boundaries.Presets.group_dimension_slugs(group_id)[:visibility]

    if Bonfire.Boundaries.Presets.slug_scope(visibility) not in ["members", nil] do
      group_id
      |> Bonfire.Boundaries.Circles.get_stereotype_circles([:group_members])
      |> List.first()
    end
  end

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

  @doc """
  Lists the direct topics of several groups in one boundary-aware query.

  Returns `%{group_id => [topic]}` and omits groups without visible topics.
  """
  def list_topics_for_groups(groups, opts \\ []) when is_list(groups) do
    case Enums.ids(groups) do
      [] ->
        %{}

      group_ids ->
        Category
        |> Queries.query([
          :default,
          type: :topic,
          parent_category: group_ids
        ])
        |> boundarise(category.id, opts ++ [verbs: [:see]])
        |> repo().many()
        |> Enum.group_by(&e(&1, :tree, :parent_id, nil))
    end
  end

  @doc """
  Lists a group's moderators: the member subjects of its `group_moderators` circle.
  """
  def moderators(category),
    do: Bonfire.Boundaries.Scaffold.Groups.list_moderators(category)

  @doc "Who is notified of what a group's moderators decide on (a request to join it, a report on something in it): the group itself, whose inbox is its moderation page, and each of its moderators."
  def moderation_recipients(group), do: [group | moderators(group)]

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

  def create_remote(attrs, opts \\ []) do
    # everything routed here federated as a Group (see `federation_module/0`), including actors an admin configured to be rewritten to one, so record it as such: the type drives which boundaries get set up
    # use canonical username for character
    declarations = opts[:remote_declarations] || %{}

    # set up as a group whatever it turns out to be (its circles hold who moderates it and, for a group, who belongs), then given the type its declarations say (`remote_type/1`), which decides how it is shown and offered: joined, or followed
    with {:ok, group} <-
           create(
             nil,
             Enum.into(attrs, Map.merge(%{type: :group}, remote_dims(declarations))),
             false
           ) do
      sync_remote_moderators(group, declarations[:attributed_to], opts)
      maybe_set_type(group, remote_type(declarations))
    end
  end

  @doc """
  Whether a remote `Group` actor is mirrored as a `:group` or a `:topic`, from what it declares about itself (`Bonfire.Federate.ActivityPub.Adapter.remote_declarations/1`): a GROUP when people elsewhere can join it and post into it, a TOPIC when they follow it and only its owner or moderators publish there. In order:

  - it names a `broader` group (FEP-9b2b), as a Bonfire topic or subgroup does: that parent is fetched, and with no `members`, or the parent's, it is a topic; with members of its own, a subgroup, so a group
  - it has a membership collection of its own (Bonfire, Mobilizon, Smithereen): a group, which keeps an archived Bonfire group a group though nobody may post there
  - only its moderators post (`postingRestrictedToMods`: PeerTube channels, WordPress blogs, Lemmy's moderator-only communities): a topic
  - it declares neither who moderates it nor who may join (a Flipboard magazine; forums that name no moderators still say who may follow, as Hubzilla's and Friendica's do): a topic
  - otherwise a group
  """
  def remote_type(declarations) do
    cond do
      is_binary(declarations[:broader]) ->
        if is_nil(declarations[:members]) or
             declarations[:members] == parent_members(declarations[:broader]),
           do: :topic,
           else: :group

      is_binary(declarations[:members]) ->
        :group

      declarations[:posting_restricted_to_mods] == true ->
        :topic

      is_nil(declarations[:attributed_to]) and is_nil(declarations[:openness]) ->
        :topic

      true ->
        :group
    end
  end

  # the membership collection the parent declares, fetched if we don't hold it yet
  defp parent_members(parent_ap_id) do
    case ActivityPub.Actor.get_cached_or_fetch(ap_id: parent_ap_id) do
      {:ok, %{data: data}} -> ActivityPub.Object.get_ap_id(data["members"])
      _ -> nil
    end
  end

  @doc """
  Converts one of our categories from a topic into a group, or back, by whoever may edit its settings (`Bonfire.Classify.ensure_update_allowed/2`). A mirror of a remote one is converted by its own declarations instead (`remote_type/1`, on every fetch).

  A topic becoming a group gets a group's scaffold (its members and moderators circles) and dimensions: its parent group's when it is in one, so a SUBGROUP, else the defaults. A group becoming a topic keeps its circles and boundaries, so converting back finds them. Either way its actor `Update` tells the instances that mirror it, which convert their copy too.
  """
  def convert(%Category{} = category, type, opts) when type in [:group, :topic] do
    current_user = current_user(opts)

    with true <-
           Bonfire.Classify.ensure_update_allowed(current_user, category) ||
             error(:not_permitted, "Only someone who may edit its settings can convert it"),
         {:ok, converted} <- maybe_set_type(category, type) do
      if type == :group and category.type != :group do
        Bonfire.Boundaries.Scaffold.Groups.create_default_boundaries(converted, current_user)
        Bonfire.Boundaries.Scaffold.Groups.block_acls(converted)

        # `replace/3` sends the actor `Update` itself
        Bonfire.Classify.Boundaries.replace(converted, current_user, parent_dims(converted))
      else
        Bonfire.Classify.Boundaries.maybe_federate_actor_update(converted)
      end

      {:ok, converted}
    end
  end

  # the dimensions of the group it is in, or none (the defaults) at the top level
  defp parent_dims(category) do
    case category |> repo().maybe_preload(:tree) |> e(:tree, :parent_id, nil) do
      parent_id when is_binary(parent_id) ->
        Bonfire.Boundaries.Presets.group_dimension_slugs(parent_id)
        |> Map.take([:membership, :visibility, :participation])
        |> Enums.filter_empty(%{})

      _ ->
        %{}
    end
  end

  defp maybe_set_type(%Category{type: type} = category, type), do: {:ok, category}

  defp maybe_set_type(%Category{} = category, type) do
    category
    |> Ecto.Changeset.change(type: type)
    |> repo().update()
  end

  # A remote group's policy isn't ours to pick, so scaffold from what the actor declares about itself: `manuallyApprovesFollowers` is how the fediverse signals request-to-join, and `postingRestrictedToMods` marks an announcement-style group only its mods post to. Visibility follows from membership via the usual cascade.
  defp remote_dims(declarations) do
    # One field, three values: `ActivityPub.Federator.Transformer.fix_openness/1` fills `openness` in from AS2's `manuallyApprovesFollowers` for actors that state only the boolean, so nothing here has to know that AS2 describes FOLLOWING while `mz:openness` describes JOINING, a distinction only groups with real membership can draw. Follow IS join across the threadiverse but not for Mobilizon, whose `Member` objects carry roles and whose `openness` describes JOINING separately. So read the more specific field first: a group that moderates entry must not be mirrored as open to join, however freely it lets people follow.
    membership =
      case declarations[:openness] do
        "moderated" -> "on_request"
        "invite_only" -> "invite_only"
        "open" -> "open"
        # nothing stated: an actor that says neither is open
        _ -> "open"
      end

    Bonfire.Classify.Boundaries.cascade_from_membership(membership)
    |> Map.put(:membership, membership)
    |> then(fn dims ->
      if declarations[:posting_restricted_to_mods],
        do: %{dims | participation: "moderators"},
        else: dims
    end)
    |> then(fn dims ->
      # unlisted where it lives, so unlisted here: readable by anyone, but no `see`, so the directory's boundary check leaves it out. A narrower visibility stays as it is
      if declarations[:discoverable] == false and dims[:visibility] == "global",
        do: %{dims | visibility: "unlisted"},
        else: dims
    end)
  end

  defp do_create(creator, attrs, is_local? \\ true) do
    # TODO: check that the category doesn't already exist (same name and parent)
    # debug(is_local?)

    cs =
      Category.create_changeset(creator, attrs, is_local?)
      |> debug()

    # boundaries are set up in the same transaction as the insert, so a group whose boundaries are refused (eg. a dimension slug that isn't offered) is never written, rather than left behind without them
    with {:ok, category} <-
           repo().transact_with(fn ->
             with {:ok, category} <- repo().insert(cs) do
               Bonfire.Classify.Boundaries.init_boundaries(
                 e(attrs, :type, nil),
                 category,
                 # A remote category has no local creator (it is governed at its origin), but local people still join, post into and moderate the local mirror, so those grants need a subject to hang off. For a topic that's the parent group, which is what actually governs it; for a top-level group it's the group itself.
                 creator || e(attrs, :parent_category, nil) || e(attrs, :parent_category_id, nil) ||
                   category,
                 attrs
               )
             end
           end) do
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

        # pin the new group to the creator's sidebar by default (pins drive the sidebar)
        maybe_pin_to_sidebar(creator, category)
      end

      # add to search index
      maybe_apply(Bonfire.Search, :maybe_index, [category, nil, creator], creator)

      # mark the new category's locality (we already know it via `is_local?`) so it classifies
      # as a feed/boundary subject (e.g. a group's own outbox) without an on-demand raising preload
      category =
        if e(category, :character, nil),
          do: Characters.mark_as(category, if(is_local?, do: :local, else: :remote)),
          else: category

      {:ok, category}
    end
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
    with {:ok, loaded_parent} <- get(id, preload: :tree, current_user: creator, verbs: [:create]) do
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
    with {:ok, parent_category} <-
           get(id, preload: :tree, current_user: creator, verbs: [:create]) do
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

  # Commented out, unused (12 October): an incoming moderation activity that takes effect (`Lock`, a removal, a ban) is checked by boundaries instead, ie. whether its actor may do that verb on the object HERE, which a remote moderator may through the mirror's moderators circle (synced from the group's declared moderators, and re-synced on a refusal by `with_moderators_resynced/2`). Same-origin with the group is deliberately not enough for those (Mayel: "Boundaries; same-origin only re-syncs"); it still lets an `Add`/`Remove` trigger a re-sync, through `authority_over_group?/2` below, since what that adopts comes from the origin. Kept for its reasoning about naming several groups and objects not in the named group
  # @doc """
  # Whether a remote actor may moderate an object on a group's behalf.
  #
  # FEP-1b12's convention, which every implementor follows, is that a receiver accepts a moderation activity when its actor is listed as a moderator of the group, or is same-origin with the group.
  # Note it is NOT same-origin with the OBJECT: a moderator legitimately closes a thread whose post was authored on a third instance.
  #
  # Two things are checked, and both matter. Authority over the group the activity names, and that the object is actually in that group, otherwise moderating one group would let you close threads anywhere. A post in a group carries the group as a tag, which is also what causes the group's boost of it, so the tag is the marker and the boost is the fallback for anything ingested boost-first.
  #
  # Without this, anyone who can reach our inbox could close any thread on this instance.
  #
  # An activity may name more than one group, since addressing fields are lists. Authority over ANY of them is enough, because both conditions have to hold for the SAME group: naming a group you do moderate alongside the one the object is actually in buys nothing.
  # """
  # def remote_moderation_authority?(actor, object, group_ap_ids) when is_list(group_ap_ids) do
  #   Enum.any?(group_ap_ids, &remote_moderation_authority?(actor, object, &1))
  # end
  #
  # def remote_moderation_authority?(actor, object, group_ap_id) when is_binary(group_ap_id) do
  #   case Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(group_ap_id) do
  #     {:ok, group} ->
  #       authority_over_group?(actor, group) and object_in_group?(object, group)
  #
  #     e ->
  #       # NOTE: This MUST return a boolean and never an error tuple: `error/2` returns `{:error, …}`, which is truthy, so a caller testing it for truth would treat "no such group" as authority granted.
  #       error(e, "no such group, so no authority to check the moderation against")
  #       false
  #   end
  # end
  #
  # def remote_moderation_authority?(_actor, object, _no_group) do
  #   error(
  #     object,
  #     "refusing remote moderation that names no group: there is nothing to check authority against"
  #   )
  #
  #   false
  # end

  @doc """
  Whether a remote actor may act on a group's behalf: same-origin with it, or listed as one of its moderators.

  This is the group half of `remote_moderation_authority?/3`, without the "and the object is in that group" half, for activities that act on the GROUP itself (who moderates it) rather than on an object in it.
  """
  def authority_over_group?(actor, group) do
    same_origin?(actor, group) or Enum.any?(moderators(group), &(uid(&1) == uid(actor)))
  end

  @doc """
  The group an object was published in, or `nil`.

  Two sources, in order of how much they are worth trusting:

    * `tree.parent`, recorded at publish time and the canonical answer. This is what the UI reads to show "posted in X".
    * a `Category` among its tags, which is how a mention of a group marks an object.

  ⚠️ A post ingested into a MIRRORED community may have neither: what links it to the community is the community's BOOST of it. That is not resolvable here without a reverse query over boosts by `Category` subjects, so it is deliberately absent rather than half-done, `object_in_group?/2` answers the "is it in THIS group" question, where the group is already known and `Boosts.boosted?/2` suffices. Add the reverse lookup when a test needs a reply to inherit a mirrored community.
  Returns `{:ok, object, group_or_nil}` — the object comes back carrying whatever was preloaded to answer the question, so a caller that needs it next does not pay for the same assocs twice. Tags are only loaded when `tree.parent` did not answer, so the common case stays a single preload. Accepts an id as well as a struct, since callers often hold only a `reply_to_id`.
  """
  def group_of_object(object_or_id)

  def group_of_object(nil), do: {:error, :not_found}

  def group_of_object(id) when is_binary(id) do
    # no boundary check: this only answers WHICH group a thread is in. Whether the author may act in
    # that group is decided later, by the `:tag` check in `Bonfire.Social.Tags`.
    case Bonfire.Common.Needles.get(id, skip_boundary_check: true) do
      {:ok, object} -> group_of_object(object)
      _ -> {:error, :not_found}
    end
  end

  def group_of_object(%{} = object) do
    # `prune:` because this answers the question for ANY object, including schemas with neither assoc: a `Message` has no `tree` at all, and preloading one an object cannot have raises rather than answering nothing, which during ingest means a 500 from the inbox and a lost delivery
    object = repo().maybe_preload(object, [tree: [:parent]], prune: true)

    case e(object, :tree, :parent, nil) do
      %Bonfire.Classify.Category{} = group ->
        {:ok, object, group}

      _ ->
        object = repo().maybe_preload(object, :tags, prune: true)

        {:ok, object,
         e(object, :tags, []) |> Enum.find(&match?(%Bonfire.Classify.Category{}, &1))}
    end
  end

  # Commented out with its only caller, `remote_moderation_authority?/3` above
  # defp object_in_group?(object, group) do
  #   tagged =
  #     object
  #     |> repo().maybe_preload(:tags)
  #     |> e(:tags, [])
  #     |> Enum.any?(&(uid(&1) == uid(group)))
  #
  #   tagged or
  #     Utils.maybe_apply(Bonfire.Social.Boosts, :boosted?, [group, object], fallback_return: false)
  # end

  defp same_origin?(actor, group) do
    with actor_url when is_binary(actor_url) <- URIs.canonical_url(actor),
         group_url when is_binary(group_url) <- URIs.canonical_url(group) do
      URI.parse(actor_url).host == URI.parse(group_url).host
    else
      _ -> false
    end
  end

  @doc "Returns (or creates) the moderators circle for a group."
  def moderators_circle(group) do
    Bonfire.Boundaries.Scaffold.Groups.moderators_circle(group)
  end

  @doc """
  Populates a mirrored remote group's moderators circle from what its actor declares in `attributedTo`.

  Three shapes occur in the wild, all of them captured as fixtures: a collection URL (Lemmy, PieFed, NodeBB, Mbin), an array of inline `Person` objects (Smithereen), and nothing at all (Hubzilla, Friendica), where the only validation available to a receiver is same-origin with the group.

  Membership of this circle carries the `:moderate` grant, which is deliberate: the origin instance is the authority for its own community, and every effect this enables it could already produce by federating moderation activities. Where the list names a LOCAL user, the grant is the useful part, since they can then moderate the mirror through our own UI.

  Re-run on every fetch rather than only at creation: Lemmy re-syncs its list each time, and a stale moderator list is worse than none. A moderator we cannot resolve (an actor on a dead instance) is skipped rather than failing the group.
  """
  def sync_remote_moderators(group, attributed_to, opts \\ [])

  def sync_remote_moderators(_group, nil, _opts), do: {:ok, []}

  def sync_remote_moderators(group, attributed_to, opts) do
    with {:ok, circle} <- moderators_circle(group) do
      moderators =
        attributed_to
        |> moderator_ap_ids(opts)
        |> Enum.flat_map(fn ap_id ->
          case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(ap_id) do
            {:ok, character} ->
              [character]

            other ->
              warn(other, "skipping a moderator we could not resolve: #{ap_id}")
              []
          end
        end)

      Enum.each(moderators, &Bonfire.Boundaries.Circles.add_to_circles(&1, circle))

      # the circle moderates the mirror itself as well as what is published in it, as for a local group's moderators
      if moderators != [], do: Bonfire.Boundaries.Scaffold.Groups.empower_moderators_circle(group)

      # Reconcile rather than only add: a moderator the origin has dropped must lose `:moderate` here too, or a demotion never takes effect on the mirror and the list only ever grows.
      # The origin's declaration is the whole truth for a group we mirror, so anyone in the circle who is not in it has no other reason to be there.
      # ⚠️ Only when we resolved SOMEBODY: an unreachable collection and a genuinely empty one are the same `[]` here, and wiping every moderator because of a network blip is far worse than keeping a stale one until the next sync.
      demoted =
        if moderators != [],
          do:
            moderators(group)
            |> Enum.reject(fn existing -> Enum.any?(moderators, &(uid(&1) == uid(existing))) end),
          else: []

      Enum.each(demoted, &Bonfire.Boundaries.Circles.remove_from_circles(&1, circle))

      if demoted != [], do: info(length(demoted), "dropped moderators the origin no longer lists")

      {:ok, moderators}
    end
  end

  # A collection URL, or a collection/page we were handed inline. Either way the AP lib's `fetch_collection/2` does the work: it reads `orderedItems` or `items`, follows `first` and pages through `next`, and treats a page it cannot resolve as empty rather than crashing. Worth deferring to, since a hand-rolled version silently stops at the first page.
  @doc """
  Runs `action`, a moderation action a remote actor sent about a group we mirror or something in it, and if it is refused, re-syncs that group's moderators from its origin and runs it once more.

  Our mirror knows a group's moderators from its last sync (when fetched, and on its relayed `Add`/`Remove`), so a moderator added since, whose `Add` we missed, would otherwise be refused until the group is next fetched. The origin decides who moderates, so a stranger gains nothing but a fetch, which is why it happens at most once per group per `[Bonfire.Classify.Categories, :moderators_resync_interval]`.
  """
  def with_moderators_resynced(group_or_object, action) when is_function(action, 0) do
    case action.() do
      {:ok, _} = done ->
        done

      refused ->
        with %{} = group <- mirrored_group_of(group_or_object),
             true <- moderators_resync_due?(group),
             {:ok, %{data: %{"attributedTo" => attributed_to}}} when not is_nil(attributed_to) <-
               ActivityPub.Actor.get_cached(pointer: group),
             {:ok, [_ | _]} <- sync_remote_moderators(group, attributed_to) do
          info(group, "re-synced a mirrored group's moderators after a refused moderation action")
          action.()
        else
          _ -> refused
        end
    end
  end

  # only a group we mirror has an origin to re-sync from
  defp mirrored_group_of(%Category{} = group) do
    group = repo().maybe_preload(group, character: [:peered])
    if Bonfire.Social.is_local?(group), do: nil, else: group
  end

  defp mirrored_group_of(object) do
    case group_of_object(object) do
      {:ok, _, %Category{} = group} -> mirrored_group_of(group)
      _ -> nil
    end
  end

  defp moderators_resync_due?(group) do
    key = "moderators_resync:#{id(group)}"

    case Bonfire.Common.Cache.get(key) do
      {:ok, nil} ->
        Bonfire.Common.Cache.put(key, true,
          expire: Config.get([__MODULE__, :moderators_resync_interval], to_timeout(minute: 15))
        )

        true

      _ ->
        false
    end
  end

  defp moderator_ap_ids(collection, opts) when is_binary(collection) or is_map(collection) do
    # `fetch_collection/2` RAISES on an unreachable collection rather than returning an error, and a group whose moderators list happens to be down must still federate: not knowing who moderates it is a smaller problem than not having the group at all.
    case ActivityPub.Federator.Fetcher.fetch_collection(collection, opts) do
      {:ok, items} -> moderator_ap_ids(items, opts)
      other -> warn(other, "could not read the moderators collection") && []
    end
  rescue
    e ->
      warn(e, "could not read the moderators collection, continuing without it")
      []
  end

  # Smithereen and NodeBB send the moderators inline as actor objects, where Lemmy, PieFed and Mbin point at a collection of ids. `ActivityPub.Utils.ap_id/1` already normalises both (and warns on anything it cannot read), so there is nothing for us to add.
  defp moderator_ap_ids(list, _opts) when is_list(list),
    do: list |> Enum.map(&ActivityPub.Utils.ap_id/1) |> Enum.reject(&is_nil/1)

  defp moderator_ap_ids(_, _), do: []

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
  Batch-resolves the subject's standing in each group: `true` (member), `:requested` (pending join request), or absent. At most two queries.
  """
  def my_membership_states(nil, _group_ids), do: %{}

  def my_membership_states(subject, group_ids) when is_list(group_ids) do
    memberships = member_of_groups?(subject, group_ids)

    case Enum.reject(group_ids, &Map.has_key?(memberships, &1)) do
      [] ->
        memberships

      remaining_ids ->
        Bonfire.Social.Requests.get_pending!(
          subject,
          Bonfire.Boundaries.Verbs.get_id!(:join),
          remaining_ids,
          preload: false,
          skip_boundary_check: true
        )
        |> Map.new(&{e(&1, :edge, :object_id, nil), :requested})
        |> Map.merge(memberships)
    end
  end

  @doc "Lists visible, active groups the user belongs to, independently of following. Membership and optional `:search` filtering happen before pagination."
  def list_joined_groups(current_user, opts \\ []) do
    member_group_ids =
      Bonfire.Boundaries.Circles.query_object_ids_for_member(current_user, :group_members)

    Category
    |> Queries.query([:default, type: :group, search: Keyword.get(opts, :search, "")])
    |> where([category: category], category.id in subquery(member_group_ids))
    |> proload([:settings, :peered])
    |> list(Keyword.put(opts, :current_user, current_user))
  end

  @doc """
  Become a member of a group, which is what an AP `Join` means.

  Membership alone: no `Follow` edge is created, so a caller that wants the group's feed as well asks for it, and `join_and_follow_group/3` is the pair. Idempotent, since that pair calls this without checking.

  A group that reviews entry gets a request typed by the `:join` verb rather than a follow standing in for one, which is what lets someone hold a pending request and a real subscription to the same group at once. A group granting neither `:join` nor `:request` refuses, rather than queueing something it will never accept.
  """
  def join_group(current_user, group_or_id, opts \\ []) do
    # a wider list than the `:read` that `Categories.one/2` defaults to, because a members-private but discoverable group shows its "Request to join" button to non-members and the button sends an ID, so a `:read`-only fetch fails for exactly the users this flow exists for. `{:any, …}` rather than a list, which would need ALL of them: this passes for someone holding at least one of the verbs, each judged on its own. Reaching the group is all it decides — whether they may actually join is the gate below. Passing a struct is not boundary-checked here at all, so this also brings the two paths closer.
    with {:ok, group} <-
           maybe_fetch(group_or_id,
             current_user: current_user,
             verbs: {:any, [:see, :read, :request]}
           ),
         group = repo().maybe_preload(group, :character),
         {:ok, circle} <- members_circle(group) do
      skip? = Keyword.get(opts, :skip_boundary_check, false)

      cond do
        Bonfire.Boundaries.Circles.is_encircled_by?(current_user, circle) ->
          {:ok, joined()}

        # `:join` is granted positively by the membership dimension (`everyone_may_join` / `locals_may_join`), so the verb already carries the "only the open slugs admit outright" rule that used to be spelled out as a slug list here
        skip? or Bonfire.Boundaries.can?(current_user, :join, group) ->
          encircled = Bonfire.Boundaries.Circles.add_to_circles(current_user, circle)
          maybe_pin_to_sidebar(current_user, group)
          maybe_tell_remote_group(current_user, :join, group, opts)

          # the new row's id travels with the answer so an AP caller can tie it to the activity that caused it, without re-deriving which membership it just made
          {:ok, Map.put(joined(), :encircle_id, id(encircled))}

        # already waiting: pressing Join sends both a `Follow` and a `Join` (for software that reads either), and a group that reviews joins reads each as asking to join, so whichever arrives second finds the first request rather than making another, as a member joining again finds their membership
        Bonfire.Social.Requests.requested?(
          current_user,
          Bonfire.Boundaries.Verbs.get_id!(:join),
          group
        ) ->
          {:ok, %{requested: true}}

        Bonfire.Boundaries.can?(current_user, :request, group) ->
          with {:ok, _} = requested <- request_to_join(current_user, group, opts) do
            maybe_tell_remote_group(current_user, :join, group, opts)
            requested
          end

        true ->
          {:error, :invite_only}
      end
    end
  end

  defp request_to_join(current_user, group, opts) do
    opts =
      opts
      |> Keyword.put_new(:to_feeds, notifications: moderation_recipients(group))
      # addressed to the moderators circle as well as the group, so those who decide on it can read it wherever it appears, including the group's inbox (its moderation page). A request is otherwise addressed to its object alone (`Requests`)
      |> Keyword.put_new(
        :to_circles,
        case moderators_circle(group) do
          {:ok, circle} -> [id(group), id(circle)]
          _ -> [id(group)]
        end
      )

    with {:ok, _request} <-
           Bonfire.Social.Requests.request(
             current_user,
             Bonfire.Boundaries.Verbs.get_id!(:join),
             group,
             opts
           ) do
      # `member: false` is knowledge rather than a redundant check: a request exists precisely because joining did not happen, and callers rendering a membership state need the answer rather than a missing key
      {:ok, %{requested: true, member: false}}
    end
  end

  @doc """
  Join a group and follow it.

  Unconditional, exactly as `leave_and_unfollow_group/3` is unconditional in reverse: both halves are attempted whatever the actor already holds, which is why each half is idempotent on its own. This is what every caller with a KNOWN intent uses — the UI Join button, the GraphQL mutation, the Masto adapter, `bonfire_ghost` — because someone pressing a control labelled "Join" means both whether or not they already followed. Status decides which control is rendered; intent decides which function is called.
  """
  def join_and_follow_group(current_user, group_or_id, opts \\ []) do
    with {:ok, group} <-
           maybe_fetch(group_or_id,
             current_user: current_user,
             verbs: {:any, [:see, :read, :request]}
           ),
         {:ok, joined} <- join_group(current_user, group, opts),
         {:ok, followed} <- follow_group(current_user, group, opts) do
      {:ok, Map.merge(followed, joined)}
    end
  end

  @doc """
  Subscribe to a group's feed without joining it.

  Its own act, which is what lets someone leave a group and keep reading it (`leave_group/3` deliberately keeps the follow). Where a caller means "join", including one acting on a remote `Follow` of a group, use `follow_and_maybe_join_group/3` instead.

  This adds nothing to `Follows.follow/3` but the group-shaped answer. That function already fetches the group, gates on the `:follow` verb (falling back to a request if only `:request` is granted), and is idempotent for someone who already follows, since `do_follow/3` answers `maybe_already_followed/2` on conflict. So the guard `join_and_follow_group/3` depends on — calling this without checking must not raise a duplicate-`Follow` unique-index violation — is kept one level down, and repeating it here would only cost a second query.

  The `:follow` verb has one home and the visibility dimension is what grants it, which is how a group that merely reviews ENTRY still accepts an ordinary follow.

  Answers only what following decided, `following:` or `requested:`, leaving membership to whoever knows it. The coupled entry points merge the two halves.
  """
  def follow_group(current_user, group_or_id, opts \\ []) do
    case Bonfire.Social.Graph.Follows.maybe_follow(current_user, group_or_id, opts) do
      # the edge's id travels with the answer so an AP caller can tie it to the activity that caused it
      {:ok, %Bonfire.Data.Social.Follow{id: id} = follow} ->
        {:ok, %{following: true, follow_id: id}}

      {:ok, _request} ->
        {:ok, %{requested: true}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Stop following a group's feed, keeping membership.

  The reverse of `follow_group/3`, and its own function rather than a bare `Follows.unfollow/3` because the reverse direction is where side effects accumulate, as `leave_group/3` unpinning from the sidebar already shows, and there is nowhere to put them on a pass-through.
  """
  def unfollow_group(current_user, group_or_id, opts \\ []) do
    Bonfire.Social.Graph.Follows.unfollow(current_user, group_or_id, opts)
    {:ok, %{following: false}}
  end

  @doc """
  Act on an incoming `Follow` of a group, whose meaning the message itself does not settle.

  From Lemmy a `Follow` means "join"; from Mobilizon it means only "subscribe", and Mobilizon sends `Join` for the other. So the rule is: always do the act you were sent, and add the other half only for someone who was not already following, since a repeat `Follow` (Lemmy re-sends periodically to keep a subscription alive) is the same choice restated rather than a request for more. A `Follow` therefore ALWAYS produces a follow and SOMETIMES also membership, never a join alone, which is why the name says `maybe_join` rather than "and/or".

  Only the AP ingest path needs this, since every other caller knows its own intent. It deliberately does NOT live inside `join_and_follow_group/3`, which would break the UI: a local user who already follows and then presses Join would take the "already holds one" branch and stay a non-member, having just asked to join.

  `invite_only` decides only the join half, being a membership value. A `Follow` of an invite-only group whose visibility permits following is a legitimate subscription, so it is honoured without membership.
  """
  def follow_and_maybe_join_group(current_user, group_or_id, opts \\ []) do
    with {:ok, group} <-
           maybe_fetch(group_or_id,
             current_user: current_user,
             verbs: {:any, [:see, :read, :request]}
           ),
         # an existing follower is restating the same choice, so there is nothing to do and nothing to widen. Membership needs no query of its own: `join_group/3` is idempotent, so a member who was not following simply gets their own membership reported back
         false <- Bonfire.Social.Graph.Follows.following?(current_user, group),
         {:ok, followed} <- follow_group(current_user, group, opts) do
      case join_group(current_user, group, opts) do
        {:ok, joined} -> {:ok, Map.merge(followed, joined)}
        # `invite_only` decides the join half only, so the subscription stands on its own
        _refused -> {:ok, followed}
      end
    else
      true -> {:ok, %{following: true}}
      other -> other
    end
  end

  defp joined, do: %{member: true}

  @doc """
  Accept a pending join request for a group, adding the requester to its members circle.

  The request is typed by the `:join` verb rather than being a follow awaiting approval. Accepting it also makes the requester a follower, since pressing Join asks for both and the group's posts are delivered to followers: their pending follow request on the group is accepted if they have one, and otherwise they are followed for. For a remote requester that follow is recorded here and not federated, since it would have to be sent as them.

  Refuses any request that is not a join request, and checks the accepter may mediate the group, both before the request is consumed.
  """
  def accept_join_request(admin, request_or_id, opts \\ []) do
    accept_opts = Keyword.merge([current_user: admin, skip_boundary_check: true], opts)
    join_verb = Bonfire.Boundaries.Verbs.get_id!(:join)

    with {:ok, group} <- join_request_group(admin, request_or_id),
         # deleted once accepted, as a follow request is: that also removes its notification from any open feed, so the row cannot be accepted twice
         {:ok, follow} <-
           Bonfire.Social.Requests.accept_and_delete(request_or_id, join_verb, accept_opts),
         requester = e(follow, :edge, :subject, nil) || e(follow, :edge, :subject_id, nil),
         {:ok, circle} <- members_circle(group) do
      if requester do
        with {:error, _} = err <- Bonfire.Boundaries.Circles.add_to_circles(requester, circle) do
          err
        else
          _ ->
            # subject is the requester, not the admin
            maybe_pin_to_sidebar(requester, group)
            maybe_follow_after_join(requester, group, accept_opts)
            maybe_accept_remote_join(requester, group)
            # accepting the request both grants membership and clears the asking
            {:ok, %{member: true, requested: false}}
        end
      else
        error(follow, "Could not find requester from follow request")
      end
    end
  end

  # A remote requester's own instance learns the decision only if we send it: without this their join stays pending there after it was accepted here. Their `Join` is read from the AP store, since the request row does not keep it. An ignored request sends nothing
  defp maybe_accept_remote_join(requester, group) do
    with {:ok, %{local: false, ap_id: requester_ap_id}} <-
           ActivityPub.Actor.get_cached(pointer: requester),
         {:ok, %{ap_id: group_ap_id}} <- ActivityPub.Actor.get_cached(pointer: group),
         %{} = join <-
           ActivityPub.Object.fetch_latest_activity(requester_ap_id, group_ap_id, "Join") do
      Bonfire.Federate.ActivityPub.Outgoing.send_accept(group, join)
    end
  end

  # Pressing Join asks to join AND follow (`join_and_follow_group/3`). Where the group's visibility grants non-members no `:follow`, the follow waits as its own request beside the join, so accepting the join settles it too.
  defp maybe_follow_after_join(requester, group, opts) do
    case Bonfire.Social.Requests.get(requester, Bonfire.Data.Social.Follow, group,
           skip_boundary_check: true
         ) do
      {:ok, request} -> Bonfire.Social.Graph.Follows.accept(request, opts)
      _ -> follow_as_member(requester, group)
    end
  end

  # A member is made a follower because the group's posts are delivered to its followers, and a member they never reach is a member in name only. For a remote member the follow is ours to record and nobody's to send, since it would be a `Follow` signed as them: `Outgoing.maybe_federate/4` already refuses a remote subject, and `incoming: true` says so here rather than queueing an attempt it will drop. A peer that sends `Join` alone (Mobilizon) delivers to members itself and never sends the `Follow`
  defp follow_as_member(member, group) do
    member =
      case is_binary(member) && Bonfire.Common.Needles.get(member, skip_boundary_check: true) do
        {:ok, loaded} -> loaded
        false -> member
        _ -> nil
      end

    member = repo().maybe_preload(member, character: [:peered])

    if member && not Bonfire.Social.Graph.Follows.following?(member, group),
      do:
        Bonfire.Social.Graph.Follows.follow(member, group,
          skip_boundary_check: true,
          incoming: not Bonfire.Social.is_local?(member)
        )
  end

  # Whether the actor sent a `Follow` of the group that they have not undone, read from the AP store because that is the only record of who sent what: the follow edge looks the same whether they asked for it or `follow_as_member/2` made it for their membership
  defp sent_own_follow?(activity, group_object) do
    actor = ActivityPub.Object.actor_id_from_data(e(activity, :data, nil))

    case ActivityPub.Object.fetch_latest_activity(
           actor,
           ActivityPub.Object.get_ap_id(group_object),
           "Follow"
         ) do
      %{data: %{"id" => follow_id}} ->
        is_nil(ActivityPub.Object.fetch_latest_activity(actor, follow_id, "Undo"))

      _ ->
        false
    end
  end

  @doc "Leave a group, unfollowing and removing from the members circle."
  def leave_and_unfollow_group(current_user, group_or_id, opts \\ []) do
    with {:ok, left} <- leave_group(current_user, group_or_id, opts) do
      Bonfire.Social.Graph.Follows.unfollow(current_user, group_or_id, opts)
      {:ok, Map.put(left, :following, false)}
    end
  end

  @doc """
  Leave a group by removing membership and its sidebar pin, preserving the current follow state.

  Also withdraws a pending join request, since someone leaving a group they asked to join means they no longer want in. The request is typed by the `:join` verb, so it has to be cancelled here rather than riding along with an unfollow as it did when a pending join WAS a pending follow.
  """
  def leave_group(current_user, group_or_id, opts \\ [])

  def leave_group(current_user, id, opts) when is_binary(id) do
    with {:ok, group} <- maybe_fetch(id, current_user: current_user) do
      leave_group(current_user, group, opts)
    end
  end

  def leave_group(current_user, group, opts) do
    with {:ok, circle} <- members_circle(group) do
      # read before anything is removed: a `Leave` from someone the group never had, or who never asked, is noise
      tell_remote_group? =
        remote_group_to_tell?(group, opts) and
          (Bonfire.Boundaries.Circles.is_encircled_by?(current_user, circle) or
             Bonfire.Social.Requests.requested?(
               current_user,
               Bonfire.Boundaries.Verbs.get_id!(:join),
               group
             ))

      Bonfire.Boundaries.Circles.remove_from_circles(current_user, [circle])
      # leaving also unpins (removes from sidebar)
      Utils.maybe_apply(Bonfire.Social.Pins, :unpin, [current_user, group],
        current_user: current_user
      )

      cancel_join_request(current_user, group)

      if tell_remote_group?, do: federate_membership(current_user, :leave, group)

      {:ok, %{member: false, requested: false}}
    end
  end

  # A group hosted elsewhere only hears of a local person joining or leaving if we tell it; our mirror records the outcome meanwhile, and the group's answer settles it. Not for an act that came FROM the group (`incoming: true`). A remote person is refused by `Outgoing` itself, since nothing can be sent as them
  defp maybe_tell_remote_group(current_user, verb, group, opts) do
    if remote_group_to_tell?(group, opts), do: federate_membership(current_user, verb, group)
  end

  # names this module because `Outgoing` finds one from `{verb, object_type}`, and nothing claims `{:join, :group}`
  defp federate_membership(current_user, verb, group),
    do:
      Bonfire.Social.maybe_federate(current_user, verb, group, nil, federation_module: __MODULE__)

  defp remote_group_to_tell?(group, opts) do
    opts[:incoming] != true and
      not Bonfire.Social.is_local?(repo().maybe_preload(group, character: [:peered]))
  end

  @doc """
  Withdraw the current user's pending join request, deleting it and its notification so it can no longer be accepted. Any follow or pending follow request is left alone.

  Answers `{:error, :not_found}` when nothing is pending, including a request a moderator already declined.
  """
  def cancel_join_request(current_user, group_or_id) do
    join_verb = Bonfire.Boundaries.Verbs.get_id!(:join)

    if Bonfire.Social.Requests.requested?(current_user, join_verb, group_or_id),
      do: Bonfire.Social.Requests.unrequest(current_user, join_verb, group_or_id),
      else: {:error, :not_found}
  end

  @doc """
  Silently decline a join request: it is marked ignored (so it can still be accepted later) and nothing is sent to the requester, who can ask again. Requires `:mediate` on the group, as `accept_join_request/3` does.
  """
  def ignore_join_request(admin, request_or_id, opts \\ []) do
    with {:ok, _group} <- join_request_group(admin, request_or_id) do
      Bonfire.Social.Requests.ignore(
        request_or_id,
        Keyword.merge([current_user: admin, skip_boundary_check: true], opts)
      )
    end
  end

  # checked before a decision consumes or marks the request, so a refusal leaves it pending. The kind comes from the edge: a follow request on the same group is a `Request` row too
  defp join_request_group(admin, request_or_id) do
    join_verb = Bonfire.Boundaries.Verbs.get_id!(:join)

    case Bonfire.Social.Requests.edge(request_or_id) do
      %{table_id: ^join_verb, object_id: group_id} ->
        maybe_fetch_with_verb(admin, :mediate, group_id)

      %{table_id: _} = edge ->
        error(edge, "Only a join request can be decided as one")

      nil ->
        error(request_or_id, "Could not find the join request")
    end
  end

  # pin a group to the user's sidebar (idempotent; Pins handles boundary/federation/notify for Categories)
  defp maybe_pin_to_sidebar(current_user, group) do
    Utils.maybe_apply(
      Bonfire.Social.Pins,
      :pin,
      [current_user, group, nil, [skip_boundary_check: true]],
      current_user: current_user
    )
  end

  @doc """
  Adds someone to a group's members circle directly, without their asking.

  Useful until we have an invite flow. Only usable by someone who moderates both the group and the instance, and only to add someone local: someone on another instance joins with their own `Follow` or `Join`, which we can't send for them. `skip_boundary_check: true` skips the instance moderator rule, for callers that already decided (eg. a test's setup).
  """
  def add_member(admin, group_or_id, user_or_id, opts \\ []) do
    with {:ok, group, user} <- fetch_group_and_person(admin, group_or_id, user_or_id),
         true <-
           opts[:skip_boundary_check] == true or moderates_instance?(admin) or
             {:error, :not_permitted},
         true <-
           Bonfire.Social.is_local?(user) or
             error(:not_local, "Only someone on this instance can be added to a group"),
         {:ok, circle} <- members_circle(group) do
      Bonfire.Boundaries.Circles.add_to_circles(user, circle)
      maybe_pin_to_sidebar(user, group)
      {:ok, %{member: true, role: member_role(user, group)}}
    end
  end

  @doc "Whether `user` may add members to `group` directly (`add_member/4`), so a UI offers it only to those it would allow: someone who moderates the group and the instance."
  def can_add_members?(user, group),
    do: Bonfire.Boundaries.can?(user, :mediate, group) == true and moderates_instance?(user)

  defp moderates_instance?(user), do: Bonfire.Boundaries.can?(user, :mediate, :instance) == true

  # what adding a member and a moderator both start with: a group the adder moderates, and the person, with `character.peered` loaded so each one's locality rule and `member_role/2` can tell it without an on-demand (raising) preload
  defp fetch_group_and_person(admin, group_or_id, user_or_id) do
    with {:ok, group} <- maybe_fetch_with_verb(admin, :mediate, group_or_id),
         {:ok, user} <- Bonfire.Common.Needles.get(user_or_id, current_user: admin) do
      {:ok, group, repo().maybe_preload(user, character: [:peered])}
    end
  end

  @doc "Remove a user from a group's members circle (moderator/admin only)."
  def remove_member(admin, group_or_id, user_or_id, opts \\ []) do
    with {:ok, group} <- maybe_fetch_with_verb(admin, :mediate, group_or_id),
         {:ok, user} <- Bonfire.Common.Needles.get(user_or_id, current_user: admin),
         {:ok, circle} <- members_circle(group) do
      Bonfire.Boundaries.Circles.remove_from_circles(user, [circle])
      {:ok, true}
    end
  end

  @doc """
  Removes a post from a group: the group's boost of it goes, so it leaves the group's feed, while the post itself survives. Allowed to the group's moderators (and admins), and to the post's own author. A post the group itself wrote has no boost to remove, so it's deleted instead (`Bonfire.Social.Objects.delete/2`).
  """
  def remove_post_from_group(current_user, group_or_id, post_or_id, opts \\ []) do
    current_user = repo().maybe_preload(current_user, character: [:peered])

    # looked up as the caller, who is the one viewing it: `unboost/3` would otherwise load an id with the GROUP as viewer
    with {:ok, post} <- Bonfire.Common.Needles.get(post_or_id, current_user: current_user),
         {:ok, group} <- group_to_remove_from(current_user, group_or_id, post) do
      if author_of?(group, post) do
        # in the group's feed by authorship rather than a boost, so there's nothing to unboost: it leaves the group by being deleted, the same way any delete is
        Bonfire.Social.Objects.delete(post, current_user: current_user)
      else
        group = repo().maybe_preload(group, character: [:peered])

        # one of our moderators removing it from a group hosted elsewhere: the removal goes to the group, and the group's echo of it is what removes it here (`Objects.ap_receive_activity/3`), so it is pending until then, unless asked to apply it now as well
        pending? = Bonfire.Social.Moderations.moderating_elsewhere?(group, current_user)

        with {:ok, _} = done <-
               if(pending? and not Bonfire.Social.Moderations.apply_now?(opts),
                 do: {:ok, :pending},
                 else: Bonfire.Social.Boosts.unboost(group, post)
               ),
             # the moderation log's record of it, a `hide` (reversible: the group can boost it again) in the group's log
             {:ok, record} <-
               Bonfire.Social.Moderations.record(current_user, :hide, post,
                 scope: group,
                 pending: pending?
               ) do
          maybe_federate_removal(current_user, post, record)
          done
        end
      end
    end
  end

  # A moderator taking someone's post out of the group also tells the threadiverse the way it understands, since it ignores the group's `Undo{Announce}`: a `Delete` by the moderator, marked a removal by its `summary`, which keeps the post, and points at its record (which is how the group's echo of it is known as ours). Only for one of OUR moderators acting on someone else's post: an author taking their own post out is not a moderation action, and a remote moderator's removal reached us as their own `Delete`, which is not ours to send again
  defp maybe_federate_removal(current_user, post, record) do
    if not author_of?(current_user, post) and Bonfire.Social.is_local?(current_user) do
      # the UI does not ask for a reason yet, so `Moderations.summary/2` falls back to `hide`'s default
      maybe_apply(
        Bonfire.Federate.ActivityPub.AdapterUtils,
        :publish_moderator_delete,
        [current_user, post, nil, [pointer: record]],
        fallback_return: nil
      )
    end
  end

  @doc "Whether `remove_post_from_group/3` would allow it, so a UI offers the action only to those it would: the post's author, or someone who moderates the group."
  def can_remove_post_from_group?(current_user, group_or_id, post) do
    author_of?(current_user, post) or
      Bonfire.Boundaries.can?(current_user, :mediate, group_or_id)
  end

  # the author takes their own post out of a group they can see; anyone else has to moderate it
  defp group_to_remove_from(current_user, group_or_id, post) do
    if author_of?(current_user, post),
      do: maybe_fetch(group_or_id, current_user: current_user),
      else: maybe_fetch_with_verb(current_user, :mediate, group_or_id)
  end

  # Media has a direct `creator`, posts the `created` mixin: `preload_creator/2` loads whichever the object has
  defp author_of?(current_user, object),
    do:
      not is_nil(id(current_user)) and
        id(Bonfire.Social.Objects.object_creator(Bonfire.Social.Objects.preload_creator(object))) ==
          id(current_user)

  @doc """
  Promote a user to moderator of a group (moderator/admin only).

  Grants the `:moderate` role to the group's *moderators circle*, then
  adds the user to that circle. Because the grant is on the circle, every member of it inherits `:mediate` automatically, so promoting is just circle membership.

  Also makes them a member, because a members-private group's posts are addressed to its members circle, and a moderator who cannot read a post cannot moderate it. Membership only: they are not made to follow the group, nor is it pinned to their sidebar, since neither was asked for.
  """
  def add_moderator(admin, group_or_id, user_or_id, _opts \\ []) do
    with {:ok, group, user} <- fetch_group_and_person(admin, group_or_id, user_or_id),
         # someone local is made a member below, but someone on another instance can't be made one by us (that takes their own `Follow` or `Join`), so they are promoted only once they are a member
         true <-
           Bonfire.Social.is_local?(user) or member?(user, group) or
             error(:not_member, "Only a member of the group can be made a moderator"),
         {:ok, circle} <- moderators_circle(group),
         {:ok, members} <- members_circle(group) do
      # empower the circle on the group (no-op if already granted)
      Bonfire.Boundaries.Scaffold.Groups.empower_moderators_circle(group, admin)

      # (moved into `empower_moderators_circle/2`, which mirrors' moderator sync and group creation call too)
      # Bonfire.Boundaries.Controlleds.grant_role(circle, group, :moderate,
      #   current_user: admin,
      #   scope: group
      # )

      Bonfire.Boundaries.Circles.add_to_circles(user, [circle, members])
      maybe_federate_moderator_change(admin, :add, group, user)
      {:ok, %{role: member_role(user, group)}}
    end
  end

  @doc """
  Demote a moderator of a group (moderator/admin only).

  Removes the user from the moderators circle; since the `:moderate` grant lives on the circle (not the user), losing membership removes the empowerment.
  """
  def remove_moderator(admin, group_or_id, user_or_id, _opts \\ []) do
    with {:ok, group} <- maybe_fetch_with_verb(admin, :mediate, group_or_id),
         {:ok, user} <- Bonfire.Common.Needles.get(user_or_id, current_user: admin),
         {:ok, circle} <- moderators_circle(group) do
      Bonfire.Boundaries.Circles.remove_from_circles(user, [circle])
      maybe_federate_moderator_change(admin, :remove, group, user)
      {:ok, true}
    end
  end

  # tells the group's followers, so a peer's mirror need not wait for its next refetch. Only for our own groups: a local moderator of a mirrored group has to act at the origin instead
  defp maybe_federate_moderator_change(admin, verb, group, user) do
    if Bonfire.Social.is_local?(repo().maybe_preload(group, character: [:peered])),
      do:
        Bonfire.Social.maybe_federate(admin, verb, group, nil,
          federation_module: __MODULE__,
          moderator: user
        )
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
  How new members join a group, from its membership dimension.
  Returns `"free"`, `"request"`, or `"invite"`.

  Read from the membership slug's own `join_mode:` in `:preset_dimensions`, so adding a membership slug gives it a join mode in the same place it is defined, rather than in a list elsewhere that has to be found and updated.

  These three values are a public contract, not an internal name: the Mastodon-compatible groups API returns `join_mode` verbatim and derives `Account.locked` from it.
  """
  def join_mode(preset_boundary) when is_binary(preset_boundary) do
    case preset_boundary do
      # legacy PRESET names rather than membership slugs, kept so objects created before the
      # dimensions existed still answer this question
      "visible" ->
        "request"

      "private" ->
        "invite"

      slug ->
        Bonfire.Boundaries.Presets.dimension_slug_meta(:membership, slug)[:join_mode] ||
          (warn(slug, "no join_mode declared for this membership slug, treating as free") &&
             "free")
    end
  end

  def join_mode({preset_boundary, _name}) when is_binary(preset_boundary) do
    join_mode(preset_boundary)
  end

  def join_mode(group) do
    group
    |> Bonfire.Boundaries.Presets.membership_slug()
    |> join_mode()
  end

  @doc """
  Whether Follow is the natural action for a group with this membership, rather than Join or Request.

  Anything but `"request"`: an invite-only announcement channel surfaces Follow as its primary action, and a freely-joinable group offers both.
  """
  def follow_eligible?(membership), do: join_mode(membership) != "request"

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

  @doc "Returns member-circle counts for several groups in one query."
  def member_counts(groups) when is_list(groups) do
    Bonfire.Boundaries.Circles.count_members_of_objects(groups, :group_members)
  end

  @doc "Lists members of a group (via members circle) or topic (via followers), returning user structs."
  def list_members(group_or_topic, opts \\ []) do
    if e(group_or_topic, :type, nil) == :group do
      role = opts[:role]

      circle_result =
        case role do
          "moderator" ->
            Bonfire.Boundaries.Scaffold.Groups.moderators_circle(group_or_topic)

          "admin" ->
            # Admin is the single custodian — skip circle query
            custodian =
              e(group_or_topic, :tree, :custodian, nil) ||
                e(group_or_topic, :tree, :custodian_id, nil)

            if custodian,
              do: {:ok, :custodian, custodian},
              else: {:error, :no_custodian}

          _ ->
            members_circle(group_or_topic)
        end

      case circle_result do
        {:ok, :custodian, custodian} ->
          case (is_struct(custodian) && {:ok, custodian}) ||
                 Bonfire.Common.Needles.get(custodian, opts) do
            {:ok, user} -> %{edges: [user], page_info: %{}}
            _ -> %{edges: [], page_info: %{}}
          end

        {:ok, circle} ->
          result = Bonfire.Boundaries.Circles.list_members(circle, opts)

          edges =
            e(result, :edges, []) |> Enum.map(&e(&1, :subject, nil)) |> Enum.reject(&is_nil/1)

          %{result | edges: edges}

        _ ->
          []
      end
    else
      result = Bonfire.Social.Graph.Follows.list_followers(group_or_topic, opts)

      edges =
        e(result, :edges, result || [])
        |> Enum.map(&(e(&1, :edge, :subject, nil) || &1))
        |> Enum.reject(&is_nil/1)

      if is_map(result) do
        %{result | edges: edges}
      else
        edges
      end
    end
  end

  @doc "Returns true if new users are configured to auto-join this group on registration."
  def auto_join_new_users?(group) do
    hooks =
      Config.get([Bonfire.Me.Users, :after_signup_hooks], [])

    gid = id(group)

    Enum.any?(hooks, fn
      {_m, _f, [first_arg | _]} -> first_arg == gid
      _ -> false
    end)
  end

  @doc "Adds or removes the auto-join hook for this group from the instance signup hooks setting."
  def set_auto_join_new_users(group_or_id, enabled, opts \\ [])

  def set_auto_join_new_users(group_or_id, true, opts) do
    hook =
      {Bonfire.Classify.Categories, :join_and_follow_group,
       [id(group_or_id), [skip_boundary_check: true]]}

    current =
      Config.get([Bonfire.Me.Users, :after_signup_hooks], [])

    Bonfire.Common.Settings.put(
      [Bonfire.Me.Users, :after_signup_hooks],
      Enum.uniq([hook | current]),
      [scope: :instance] ++ opts
    )
  end

  def set_auto_join_new_users(group_or_id, false, opts) do
    gid = id(group_or_id)

    current =
      Config.get([Bonfire.Me.Users, :after_signup_hooks], [])

    updated =
      Enum.reject(current, fn
        {_m, _f, [first_arg | _]} -> first_arg == gid
        _ -> false
      end)

    Bonfire.Common.Settings.put(
      [Bonfire.Me.Users, :after_signup_hooks],
      updated,
      [scope: :instance] ++ opts
    )
  end

  @doc "Returns deduplicated outbox feed IDs for a category and its subcategories."
  def group_feed_ids(category, subcategories \\ []) do
    ([e(category, :character, :outbox_id, nil) || id(category)] ++
       Enum.map(subcategories, &(e(&1, :character, :outbox_id, nil) || id(&1))))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def group_and_child_ids(category, subcategories \\ []) do
    ([id(category)] ++
       Enums.ids(subcategories))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Filters a list of categories/topics to only those with a name."
  def filter_named(list) do
    Enum.filter(list, &(e(&1, :profile, :name, nil) || e(&1, :name, nil)))
  end

  @doc "Checks whether the current user is allowed to create a group given instance settings."
  def can_create_group?(current_user) do
    # TODO: use instance boundaries instead of settings?
    if Config.get([Bonfire.UI.Groups, :create_groups], :everyone) == :admins and
         !Bonfire.Boundaries.can?(current_user, :configure, :instance) do
      {:error, l("Only admins can create groups")}
    else
      :ok
    end
  end

  defp maybe_fetch(group_or_id, opts \\ [])
  defp maybe_fetch(%{id: _} = group, _opts), do: {:ok, group}
  defp maybe_fetch(id, opts) when is_binary(id), do: get(id, opts)

  # Single-query fetch+authz: passes verbs: to get/2 when fetching by ID; when a struct is
  # already available, falls back to a separate can? check to avoid a redundant DB round-trip.
  defp maybe_fetch_with_verb(user, verb, %{id: _} = group) do
    if Bonfire.Boundaries.can?(user, verb, group),
      do: {:ok, group},
      else: {:error, :not_permitted}
  end

  # `verbs:`, since `boundarise` ignores a singular `verb:` and would check only `:read`
  defp maybe_fetch_with_verb(user, verb, id) when is_binary(id) do
    get(id, current_user: user, verbs: [verb])
  end

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

      with {:ok, category} = done <-
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
             end) do
        # tells the group's followers elsewhere about the new name, summary or images; after the transaction, so a delivery failure can't undo the edit. Not for a mirror taking its origin's changes (`update_remote_actor/2`), which would speak for someone else's group; its row may not be marked remote yet when it is first created, so this goes by the caller's `is_local?`
        if is_local?, do: Bonfire.Classify.Boundaries.maybe_federate_actor_update(category)
        done
      end
    else
      error(category, "Sorry, you cannot edit this.")
    end
  end

  # with opts rather than a user, as `Bonfire.Social.Objects.delete/2` calls it: its permission is not checked again, since `Objects.delete/2` already did, and for a mirror the origin's own deletion was verified (its actor is served as a tombstone). So a group deleted at its origin is archived here, for its admin to clean up later
  def soft_delete(%Category{} = c, opts) when is_list(opts), do: archive(c, current_user(opts))

  def soft_delete(%Category{} = c, user) do
    if Classify.ensure_update_allowed(user, c) do
      archive(c, user)
    else
      error("Sorry, you cannot archive this.")
    end
  end

  def soft_delete(id, user) when is_binary(id) do
    with {:ok, c} <- get(id, current_user: user, verbs: [:delete]) do
      soft_delete(c, user)
    end
  end

  defp archive(%Category{} = c, user) do
    maybe_apply(Bonfire.Search, :maybe_unindex, [c])

    # read before archiving, since an archived group is no longer found by the lookups that format its actor
    ap_actor = Bonfire.Classify.Boundaries.local_ap_actor(c)
    # and who to tell, while its followers can still be resolved
    recipients = Bonfire.Classify.Boundaries.archive_recipients(ap_actor)

    with {:ok, c} <-
           repo().transact_with(fn ->
             # archived through its POINTER, so everything that goes through pointers (feeds, search, boundaries, the AP adapter) leaves it out. Needle then deletes its row, losing only its own `type`, which `unarchive/2` gives back when it recreates the row (`Repo.Delete.restore_soft_deleted/2`); its mixins hang off the pointer and stay
             with {:ok, pointer} <-
                    Bonfire.Common.Needles.one(id(c), skip_boundary_check: true),
                  {:ok, _} <- Bonfire.Common.Repo.Delete.soft_delete(pointer) do
               # ⚠️ DISABLED 2026-09-08, still wanted: `:lock` grants `cannot_participate_or_more`, which also denies `:edit`/`:mediate` and so locked mods out of restoring. Needs a `:tag`-only deny; tests parked in `group_archive_test.exs`
               # Bonfire.Boundaries.Blocks.lock(c, current_user: user)

               {:ok, c}
             else
               e ->
                 {:error, e}
             end
           end) do
      # after the transaction, so a delivery failure can't undo the archive
      Bonfire.Classify.Boundaries.maybe_federate_archive(c, user, ap_actor, recipients)

      {:ok, c}
    end
  end

  @doc """
  Irreversibly deletes a group or topic, and federates a `Delete` of its actor.

  Named to pair with `soft_delete/2` so the two cannot be reached for by accident: archiving is reversible (`unarchive/2`) and stays local, because a federated `Delete` is not reversible and would strand every remote mirror as a tombstone we could never undo. This one is the irreversible act, so it is the one that tells other instances.

  Deletion itself goes through the same generic path a user's does (`Objects.maybe_generic_delete/3`), whose epic is what emits the `Delete`.
  """
  def hard_delete(category, opts \\ [])

  def hard_delete(%Category{} = category, opts) do
    user = current_user(opts)

    # TODO: check :delete boundary instead
    if Classify.ensure_update_allowed(user, category) do
      maybe_apply(Bonfire.Search, :maybe_unindex, [category])

      # `character: [:peered]` because the federation act classifies the actor's locality, and that check raises rather than guessing when `peered` is not loaded
      category =
        repo().maybe_preload(category, [:settings, :character, profile: [:icon, :image]])
        |> repo().maybe_preload(character: [:peered])

      maybe_apply(Bonfire.Social.Objects, :maybe_generic_delete, [
        Category,
        category,
        Keyword.merge(opts,
          current_user: user,
          delete_associations: [:settings, :character, :profile, :tree],
          delete_caretaken: true,
          delete_media: [e(category, :profile, :icon, nil), e(category, :profile, :image, nil)]
        )
      ])
    else
      error("Sorry, you cannot delete this.")
    end
  end

  def hard_delete(id, opts) when is_binary(id) do
    with {:ok, category} <- get(id, Keyword.put(opts, :verb, :delete)) do
      hard_delete(category, opts)
    end
  end

  @doc """
  Restores an archived group (`soft_delete/2`): recreates its row, which archiving it through its pointer deleted, and re-indexes it. Gated by the same `ensure_update_allowed/2`, asked about the archived pointer.
  """
  def unarchive(%Category{} = c, user), do: unarchive(id(c), user)

  def unarchive(id, user) when is_binary(id) do
    with {:ok, archived} <- get_archived(id),
         true <-
           Classify.ensure_update_allowed(user, archived, include_deleted: true) ||
             error(:not_permitted, "Sorry, you cannot restore this."),
         {:ok, _} <-
           repo().transact_with(fn ->
             # ⚠️ DISABLED with the lock in `soft_delete/2`, see the note there
             # Bonfire.Boundaries.Blocks.unlock(c, current_user: user)

             Bonfire.Common.Repo.Delete.restore_soft_deleted({Category, id}, %{
               type: archived_type(archived)
             })
           end),
         {:ok, c} <- get(id, skip_boundary_check: true) do
      maybe_apply(Bonfire.Search, :maybe_index, [c, nil, user], user)

      # after the transaction, so a delivery failure can't undo the restore
      Bonfire.Classify.Boundaries.maybe_federate_unarchive(c, user)

      {:ok, c}
    end
  end

  @doc """
  Restores a mirror its origin deleted and then restored (an incoming `Undo{Delete}`, believed once the origin serves the group again): no permission to check here, the origin's act is the authority. The archived copy's row is recreated as `unarchive/2` does.
  """
  def restore_remote(id) do
    with {:ok, archived} <- get_archived(id) do
      Bonfire.Common.Repo.Delete.restore_soft_deleted({Category, uid(id)}, %{
        type: archived_type(archived)
      })
    end
  end

  @doc """
  An archived group, rebuilt from its pointer: archiving deletes the group's row (`soft_delete/2`), so it has only its id and its mixins (profile, character, tree, settings…), which hang off the pointer. Built as a group, since only groups are archived. Not boundarised: callers decide who may see it, eg. with `Classify.ensure_update_allowed/3` and `include_deleted: true`.
  """
  def get_archived(id_or_username) do
    case archived_groups([archived_id(id_or_username)]) do
      [archived] -> {:ok, archived}
      _ -> {:error, :not_found}
    end
  end

  # a group's page is reached by its username too, which lives on its character, a mixin that survives archiving
  defp archived_id(id_or_username) do
    uid(id_or_username) ||
      from(c in Bonfire.Data.Identity.Character,
        where: c.username == ^to_string(id_or_username),
        select: c.id
      )
      |> repo().one()
  end

  @doc """
  An archived category's `type`, for restoring it: archiving deleted the row that held it, so it's read from what survives. A group has a members circle (a separate object it caretakes), a topic doesn't. ⚠️ A topic converted from a group keeps its circles (`convert/3`), so it reads as a group.
  """
  def archived_type(id) do
    if Bonfire.Boundaries.Circles.caretakers_with_stereotype([uid(id)], :group_members) != [],
      do: :group,
      else: :topic
  end

  @doc "The archived groups (and topics) among `ids` (a list, or a query selecting ids), as `get_archived/1` builds them."
  def archived_groups([]), do: []

  def archived_groups(ids) when is_list(ids),
    do:
      archived_groups_where(
        dynamic([p], p.id in ^(ids |> Enum.map(&uid/1) |> Enum.reject(&is_nil/1)))
      )

  def archived_groups(%Ecto.Query{} = ids_query),
    do: archived_groups_where(dynamic([p], p.id in subquery(ids_query)))

  defp archived_groups_where(ids_condition) do
    from(p in Needle.Pointer,
      where: p.table_id == ^Needle.Util.table_id(Category) and not is_nil(p.deleted_at),
      where: ^ids_condition,
      select: p.id
    )
    |> repo().all()
    # no `type`: archiving deleted the row holding it, and only restoring needs it back (`archived_type/1`)
    |> Enum.map(&%Category{id: &1})
    |> repo().maybe_preload([
      :tree,
      :settings,
      :created,
      profile: [:icon, :image],
      character: [:peered]
    ])
  end

  def update_local_actor(%Category{} = cat, params) do
    with {:ok, cat} <- __MODULE__.update(:skip_boundary_check, cat, params, true),
         actor <- format_actor(cat) do
      {:ok, actor}
    end
  end

  def update_local_actor(%{pointer_id: pointer_id}, params) when is_binary(pointer_id) do
    # `:default_incl_deleted` because an ARCHIVED group still has an actor to describe: archiving federates an `Update` saying the group is closed, and serialising that actor generates its keys if it has none — which writes through here. Without this the fetch finds nothing and the update it was archiving to announce never goes out. Same filter `unarchive/2` uses to find the group it is restoring
    with {:ok, cat} <- get(pointer_id, [[:default_incl_deleted], skip_boundary_check: true]) do
      update_local_actor(cat, params)
    end
  end

  # An `%ActivityPub.Actor{}` does not always carry a `pointer_id` — one built by `format_actor/1` does not — so fall back to its username, exactly as `Bonfire.Me.Users` does for the same reason. Reached when the AP library writes back through the adapter, notably `ensure_keys_present/1` generating signing keys the first time an actor is serialised
  def update_local_actor(actor, params) do
    with {:ok, cat} <-
           get(e(actor, :username, nil), [[:default_incl_deleted], skip_boundary_check: true]) do
      update_local_actor(cat, params)
    end
  end

  # returns the updated Category, NOT an actor (unlike `update_local_actor/2`, whose caller is the AP library): callers here are Bonfire-side and thread the local object onwards — `create_remote_actor/1` for one uses the result as the character it returns
  def update_remote_actor(%Category{} = cat, params) do
    {declarations, params} = Map.pop(params, :remote_declarations)

    with {:ok, cat} <- __MODULE__.update(:skip_boundary_check, cat, params, false) do
      # the category as it is after them, since its type may have changed
      case reapply_remote_declarations(cat, declarations) do
        {:ok, %Category{} = cat} -> {:ok, cat}
        _ -> {:ok, cat}
      end
    end
  end

  # A remote group's own declarations change over time: moderators come and go, and a community can flip `postingRestrictedToMods` or start requiring approval. Applying these only at creation would leave our mirror asserting whatever it declared the day we first saw it, which for the two flags means our boundaries drift out of step with the real community's rules. Lemmy re-syncs its moderators on every fetch for the same reason.
  defp reapply_remote_declarations(_cat, nil), do: :ok

  defp reapply_remote_declarations(cat, %{} = declarations) do
    # a mirror made before 23 August has no type and no group scaffold (`create_remote/2` then set neither), so set it up now, as it would be set up today, before the boundaries below need its circles
    if is_nil(e(cat, :type, nil)) do
      Bonfire.Boundaries.Scaffold.Groups.create_default_boundaries(cat)
      Bonfire.Boundaries.Scaffold.Groups.block_acls(cat)
    end

    sync_remote_moderators(cat, declarations[:attributed_to])

    # `replace/4` rather than `apply_changes/4` on purpose: the remote community is the authority on its own rules, so a declaration it has stopped sending must fall back to the default here rather than leaving our mirror asserting what it last said
    Bonfire.Classify.Boundaries.replace(
      cat,
      # the subject `do_create/3` hangs a mirror's grants off, since it has no local creator: its parent for a topic, itself for a group. Without one, the grants that need a subject are silently skipped and every refetch leaves the mirror reading as invite-only
      e(cat, :tree, :parent_id, nil) || cat,
      remote_dims(declarations)
    )

    # and what it is now, which it may have changed (eg. turning `postingRestrictedToMods` on or off): its declarations always win for a mirror
    maybe_set_type(cat, remote_type(declarations))
  end

  def update_remote_actor(%{pointer_id: pointer_id}, params) do
    with {:ok, cat} <- get(pointer_id, skip_boundary_check: true) do
      update_remote_actor(cat, params)
    end
  end

  def format_actor(cat) do
    Bonfire.Federate.ActivityPub.AdapterUtils.format_actor(cat, @federation_type)
  end

  # a moderator promoted or demoted: an `Add`/`Remove` on the group's moderators collection by the moderator who acted, which the group then announces to its followers (see `ActivityPub.add/2`), as Lemmy does
  def ap_publish_activity(subject, verb, group, opts) when verb in [:add, :remove] do
    # the outgoing gate checked the moderator who acted, not the group, so a nonfederated group would otherwise publish who moderates it
    with true <-
           Bonfire.Federate.ActivityPub.Outgoing.federate_outgoing?(group) == true ||
             {:ignore, "the group does not federate"},
         target when is_binary(target) <-
           Bonfire.Federate.ActivityPub.AdapterUtils.moderators_collection_ap_id(group) ||
             {:ignore, "the group does not publish its moderators"},
         {:ok, actor} <- ActivityPub.Actor.get_cached(pointer: subject),
         {:ok, moderator} <- ActivityPub.Actor.get_cached(pointer: opts[:moderator]) do
      params = %{actor: actor, object: moderator.ap_id, target: target}

      case verb do
        :add -> ActivityPub.add(params)
        :remove -> ActivityPub.remove(params)
      end
    end
  end

  def ap_publish_activity(subject, verb, object, _opts),
    do: ap_publish_activity(subject, verb, object)

  # a local person joining or leaving a group hosted elsewhere, reached through `Bonfire.Social.maybe_federate/3` so the usual outgoing gates apply
  def ap_publish_activity(subject, verb, group) when verb in [:join, :leave] do
    with {:ok, actor} <- ActivityPub.Actor.get_cached(pointer: subject),
         {:ok, group_actor} <- ActivityPub.Actor.get_cached(pointer: group) do
      case verb do
        :join -> ActivityPub.join(%{actor: actor, object: group_actor})
        :leave -> ActivityPub.leave(%{actor: actor, object: group_actor})
      end
    end
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
        |> ActivityPub.Actor.list_cached()
        |> Enum.map(& &1.ap_id)

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

  @doc """
  Receives a remote actor joining, following or leaving one of our groups.

  A `Follow` is ambiguous and nothing in the message settles it: Lemmy means "join" by it, Mobilizon means only "subscribe" and sends `Join` for the other. `follow_and_maybe_join_group/3` implements the reading, which is to do the act that was sent and add the other half only for an actor who held neither.

  `Join` means membership, and nothing is sent back as a `Follow`. The member is still made a follower HERE, unfederated, because the group's posts are delivered to its followers, whereas Mobilizon (which sends `Join` alone) delivers to its members collection. `Leave` drops membership and that follow with it, but keeps a follow they sent themselves, which is what lets someone keep reading a group after leaving it.

  An `invite_only` group refuses, and we answer nothing at all: a `Reject` would be more honest but it resets the sender's button and invites the same request again, and silence is what Mobilizon does too.
  """
  def ap_receive_activity(actor, %{data: %{"type" => type}} = activity, object)
      when type in ["Follow", "Join", "Leave"] do
    # the actor is resolved FIRST because the group is then fetched as them: `skip_boundary_check` has no business on an activity from a stranger, and a group they cannot see must be neither actable nor confirmed to exist by what comes back
    with {:ok, follower} <- Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(actor),
         {:ok, group} <- group_from_ap_object(object, follower) do
      # the acts stay gated for the same reason: it is what refuses a `Join` to an `invite_only` group, wherever it came from
      case type do
        "Follow" ->
          follow_and_maybe_join_group(follower, group)

        "Join" ->
          with {:ok, %{member: true}} = ok <- join_group(follower, group) do
            follow_as_member(follower, group)
            ok
          end

        "Leave" ->
          with {:ok, _} = ok <- leave_group(follower, group) do
            if Bonfire.Social.Graph.Follows.following?(follower, group) and
                 not sent_own_follow?(activity, object),
               do: Bonfire.Social.Graph.Follows.unfollow(follower, group, incoming: true)

            ok
          end
      end
      |> link_membership_records(activity)
      |> maybe_accept_activity(type, group, activity)
    end
  end

  # A group hosted elsewhere answering a local person's `Join`. The answer settles what our mirror recorded while waiting: `Accept` makes them a member and clears the pending request, `Reject` drops either. Sends nothing back (`incoming: true`), since the group already knows.
  def ap_receive_activity(
        group,
        %{data: %{"type" => type, "actor" => answering}},
        %{data: %{"type" => "Join", "actor" => joiner_ap_id} = join}
      )
      when type in ["Accept", "Reject"] do
    # the answered `Join` is found by its id alone, so this is what stops a third party answering for a group the person asked to join
    with true <-
           ActivityPub.Object.get_ap_id(join["object"]) == answering ||
             error(join, "refusing an answer to a Join from an actor it was not sent to"),
         {:ok, joiner} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(joiner_ap_id),
         {:ok, group} <- get(id(group), skip_boundary_check: true) do
      settle_join(joiner, group, type == "Accept")
    end
  end

  @doc """
  A group hosted elsewhere answered a local person's `Follow`. Where following IS joining (Lemmy, PieFed, Mbin, NodeBB), the group never answers the `Join` sent alongside, so its answer to the `Follow` settles a pending join request too. Such a group's actor declares no `members` collection, which software that answers joins itself does (Mobilizon, Smithereen, Bonfire). Not `openness`: `Transformer.fix_openness/1` fills that in on storage for any actor stating `manuallyApprovesFollowers`. Does nothing without a pending join request, since following alone is not joining.
  """
  def follow_answered(follower, group, accepted?) do
    with {:ok, %{local: false, data: %{"type" => "Group"} = data}} <-
           ActivityPub.Actor.get_cached(pointer: group),
         false <- Map.has_key?(data, "members"),
         {:ok, group} <- get(id(group), skip_boundary_check: true),
         true <-
           Bonfire.Social.Requests.requested?(
             follower,
             Bonfire.Boundaries.Verbs.get_id!(:join),
             group
           ) do
      settle_join(follower, group, accepted?)
    else
      _ -> nil
    end
  end

  # The group's answer settles what our mirror recorded while waiting: accepting makes them a member and clears the pending request, rejecting drops either. Sends nothing back (`incoming: true`), since the group already knows.
  defp settle_join(joiner, group, true = _accepted?) do
    with {:ok, _} <- join_group(joiner, group, skip_boundary_check: true, incoming: true) do
      cancel_join_request(joiner, group)
      {:ok, group}
    end
  end

  defp settle_join(joiner, group, false = _accepted?) do
    with {:ok, _} <- leave_group(joiner, group, incoming: true), do: {:ok, group}
  end

  # Only for an act that actually completed. A `Join` that became a REQUEST is answered later by the moderator's decision (`accept_join_request/3`), and an `invite_only` refusal is answered not at all: `Reject` would be more honest but it resets the sender's button and invites the same request again, and silence is what Mobilizon does. `Leave` needs no reply.
  defp maybe_accept_activity({:ok, result} = ok, type, group, activity) do
    completed? =
      case type do
        "Follow" -> e(result, :following, false)
        "Join" -> e(result, :member, false)
        _ -> false
      end

    if completed?, do: Bonfire.Federate.ActivityPub.Outgoing.send_accept(group, activity)

    ok
  end

  defp maybe_accept_activity(other, _type, _group, _activity), do: other

  # Ties the records this activity created back to it, the same link `link_ap_object/3` already makes for incoming OBJECTS and has never made for memberships.
  #
  # It is what lets an `Undo` mean "remove what this activity created" rather than re-deriving a follow from actor plus object and then guessing whether the membership came with it. That guess is unanswerable in general: for Lemmy a `Follow` IS joining, for Mobilizon it is only subscribing, and the same `Undo{Follow}` has to mean opposite things to each. Linked, there is nothing to guess.
  #
  # **Best effort, deliberately.** The act has already happened by the time this runs, so a failed link must not fail it, and `Undo` must not depend on the link existing: every follow made before this, and any whose link did not get written, has none. What a missing link costs is precision, and `Undo` falls back to re-deriving the follow and leaving membership alone, which is the conservative half of the guess and matches what happened before any of this.
  defp link_membership_records({:ok, %{encircle_id: encircle_id}} = ok, activity)
       when is_binary(encircle_id) do
    Bonfire.Federate.ActivityPub.Incoming.link_ap_object(activity, encircle_id, local?: false)
    ok
  rescue
    e ->
      # never fail an accepted membership over its bookkeeping
      error(e, "could not link the membership to the activity that created it")
      ok
  end

  defp link_membership_records(other, _activity), do: other

  # only a LOCAL group: somebody joining a remote group is that instance's business, and an object with no pointer here is not ours to act on
  defp group_from_ap_object(%{pointer_id: pointer_id}, follower) when is_binary(pointer_id),
    do: maybe_fetch(pointer_id, current_user: follower, verbs: {:any, [:see, :read, :request]})

  defp group_from_ap_object(object, _follower),
    do: error(object, "no local group to act on")

  # Handles a change to who moderates a community, which arrives as an `Add` or `Remove` targeting the collection the community's `attributedTo` names.
  #
  # Applied as a RE-SYNC of that collection rather than as a delta: idempotent, self-correcting after a delivery we missed, and what we end up asserting is what the origin publishes rather than what an activity claimed. Lemmy itself re-syncs its whole list on every fetch.
  #
  # Two things are verified first, and both matter. The community must DECLARE the targeted collection as its own, since a collection cannot say whose it is (all three we captured are a bare `OrderedCollection`), so the group's own `attributedTo` is the only link and an activity naming an unrelated community fails it. And the actor must have authority over that community, because otherwise a stranger could make us re-fetch on demand even though the state we adopt is the origin's.
  def ap_receive_activity(actor, %{data: %{"type" => type} = data}, _object)
      when type in ["Add", "Remove"] do
    with {:ok, group} <- moderated_group_for_collection(data),
         true <-
           authority_over_group?(actor, group) ||
             error(actor, "refusing a moderator change from an actor with no standing here"),
         {:ok, moderators} <- sync_remote_moderators(group, e(data, "target", nil)) do
      info(length(moderators), "re-synced the moderators of a mirrored group")
      {:ok, group}
    end
  end

  @doc """
  Receives a group that arrives as the OBJECT of an activity, e.g. a `Create{Group}`.

  That is the same thing as meeting its actor, with the same fields, policy flags and moderators, so it resolves through the actor path rather than mapping AS2 a second time. Mapping it here separately is what let the two drift: this clause used to pass the raw AS2 map through as `category:` with a hardcoded boundary, so a community that arrived this way had no name, no summary and none of its declared policy.
  """
  def ap_receive_activity(creator, activity, %{data: %{"id" => ap_id, "type" => type}} = object)
      when is_binary(ap_id) and is_binary(type) do
    if type in ActivityPub.Config.supported_actor_types() do
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(ap_id)
    else
      ap_receive_unrecognised(creator, activity, object)
    end
  end

  def ap_receive_activity(creator, activity, object),
    do: ap_receive_unrecognised(creator, activity, object)

  defp ap_receive_unrecognised(creator, _activity, object) do
    attrs = %{
      # TODO: boundaries
      boundary: "public_remote",
      # to_circles: "public",
      # TODO: map the fields
      category: e(object, :data, nil)
    }

    create(creator, attrs, false)
  end

  # The group that DECLARES this collection, among the actors the activity names. A collection does not say whose it is, so the declaration is the only link, and checking it is what stops an attacker pointing an `Add` at a community they have nothing to do with.
  # It must also actually be a group: a `Person` can have an `attributedTo` too, and that is not a moderator list.
  defp moderated_group_for_collection(data) do
    case Bonfire.Federate.ActivityPub.AdapterUtils.collection_target_id(data) do
      target when is_binary(target) ->
        Bonfire.Federate.ActivityPub.AdapterUtils.collection_owner_candidates(data)
        |> Enum.find_value(fn candidate ->
          with {:ok, %{data: %{"attributedTo" => ^target}}} <-
                 ActivityPub.Actor.get_cached(ap_id: candidate),
               {:ok, %Bonfire.Classify.Category{} = group} <-
                 Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(candidate) do
            {:ok, group}
          else
            _ -> nil
          end
        end) ||
          error(target, "no group we mirror declares this collection as its moderators")

      _ ->
        error(data, "a moderator change has to name the collection it changes")
    end
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
