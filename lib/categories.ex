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
      {"Remove", "attributedTo"}
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

  @doc """
  Lists a group's moderators: the member subjects of its `group_moderators` circle.
  """
  def moderators(category),
    do: Bonfire.Boundaries.Scaffold.Groups.list_moderators(category)

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

    with {:ok, group} <-
           create(
             nil,
             Enum.into(attrs, Map.merge(%{type: :group}, remote_dims(declarations))),
             false
           ) do
      sync_remote_moderators(group, declarations[:attributed_to], opts)
      {:ok, group}
    end
  end

  # A remote group's policy isn't ours to pick, so scaffold from what the actor declares about itself: `manuallyApprovesFollowers` is how the fediverse signals request-to-join, and `postingRestrictedToMods` marks an announcement-style group only its mods post to. Visibility follows from membership via the usual cascade.
  defp remote_dims(declarations) do
    # One field, three values: `ActivityPub.Federator.Transformer.fix_openness/1` fills `openness` in from AS2's `manuallyApprovesFollowers` for actors that state only the boolean, so nothing here has to know that AS2 describes FOLLOWING while `mz:openness` describes JOINING, a distinction only groups with real membership can draw.rue across the threadiverse but not for Mobilizon whose `Member` objects carry roles and whose `openness` describes JOINING separately. So read the more specific field first: a group that moderates entry must not be mirrored as open to join, however freely it lets people follow.
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
  end

  defp do_create(creator, attrs, is_local? \\ true) do
    # TODO: check that the category doesn't already exist (same name and parent)
    # debug(is_local?)

    cs =
      Category.create_changeset(creator, attrs, is_local?)
      |> debug()

    with {:ok, category} <-
           repo().transact_with(fn ->
             with {:ok, category} <- repo().insert(cs) do
               {:ok, category}
             end
           end) do
      with {:ok, category} <-
             Bonfire.Classify.Boundaries.init_boundaries(
               e(attrs, :type, nil),
               category,
               # A remote category has no local creator (it is governed at its origin), but local people still join, post into and moderate the local mirror, so those grants need a subject to hang off. For a topic that's the parent group, which is what actually governs it; for a top-level group it's the group itself.
               creator || e(attrs, :parent_category, nil) || e(attrs, :parent_category_id, nil) ||
                 category,
               attrs
             ) do
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
  Whether a remote actor may moderate an object on a group's behalf.

  FEP-1b12's convention, which every implementor follows, is that a receiver accepts a moderation activity when its actor is listed as a moderator of the group, or is same-origin with the group.
  Note it is NOT same-origin with the OBJECT: a moderator legitimately closes a thread whose post was authored on a third instance.

  Two things are checked, and both matter. Authority over the group the activity names, and that the object is actually in that group, otherwise moderating one group would let you close threads anywhere. A post in a group carries the group as a tag, which is also what causes the group's boost of it, so the tag is the marker and the boost is the fallback for anything ingested boost-first.

  Without this, anyone who can reach our inbox could close any thread on this instance.

  An activity may name more than one group, since addressing fields are lists. Authority over ANY of them is enough, because both conditions have to hold for the SAME group: naming a group you do moderate alongside the one the object is actually in buys nothing.
  """
  def remote_moderation_authority?(actor, object, group_ap_ids) when is_list(group_ap_ids) do
    Enum.any?(group_ap_ids, &remote_moderation_authority?(actor, object, &1))
  end

  def remote_moderation_authority?(actor, object, group_ap_id) when is_binary(group_ap_id) do
    case Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(group_ap_id) do
      {:ok, group} ->
        authority_over_group?(actor, group) and object_in_group?(object, group)

      e ->
        # NOTE: This MUST return a boolean and never an error tuple: `error/2` returns `{:error, …}`, which is truthy, so a caller testing it for truth would treat "no such group" as authority granted. 
        error(e, "no such group, so no authority to check the moderation against")
        false
    end
  end

  def remote_moderation_authority?(_actor, object, _no_group) do
    error(
      object,
      "refusing remote moderation that names no group: there is nothing to check authority against"
    )

    false
  end

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
    object = repo().maybe_preload(object, tree: [:parent])

    case e(object, :tree, :parent, nil) do
      %Bonfire.Classify.Category{} = group ->
        {:ok, object, group}

      _ ->
        object = repo().maybe_preload(object, :tags)

        {:ok, object,
         e(object, :tags, []) |> Enum.find(&match?(%Bonfire.Classify.Category{}, &1))}
    end
  end

  defp object_in_group?(object, group) do
    tagged =
      object
      |> repo().maybe_preload(:tags)
      |> e(:tags, [])
      |> Enum.any?(&(uid(&1) == uid(group)))

    tagged or
      Utils.maybe_apply(Bonfire.Social.Boosts, :boosted?, [group, object], fallback_return: false)
  end

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
  Join a group. Follows the group (for feed updates) and, if permitted, adds the user to the members circle. If the group requires approval (`:no_follow` ACL), a join request is created instead.
  """
  def join_group(current_user, group_or_id, opts \\ []) do
    # fetch by `:see`/`:request` rather than the `:read` that `Categories.one/2` defaults to: a members-private but discoverable group shows its "Request to join" button to non-members, and the button sends an ID, so a `:read` fetch fails for exactly the users this flow exists for (they are denied `:read`, and since the boundary summary aggregates with `bool_and`, listing `:read` here would let that denial veto the whole check). `:request` alone is not enough either: open groups never grant it. Passing a struct is not boundary-checked here at all, so this also brings the two paths closer. Joining itself stays gated: `do_join_group/4` still enforces `invite_only`, and `Follows.follow/3` still decides follow-vs-request by boundaries.
    with {:ok, group} <-
           maybe_fetch(group_or_id, current_user: current_user, verbs: [:see, :read, :request]),
         group = repo().maybe_preload(group, :character),
         {:ok, circle} <- members_circle(group) do
      result =
        cond do
          Bonfire.Boundaries.Circles.is_encircled_by?(current_user, circle) ->
            {:ok, joined()}

          # Already-following → add to circle without re-follow. Avoids the duplicate-Follow unique-index violation that poisons the surrounding transaction.
          Bonfire.Social.Graph.Follows.following?(current_user, group) ->
            Bonfire.Boundaries.Circles.add_to_circles(current_user, circle)
            {:ok, joined()}

          true ->
            do_join_group(current_user, group, circle, opts)
        end

      # pin once, only when the user actually became a member
      with {:ok, %{member: true}} <- result do
        maybe_pin_to_sidebar(current_user, group)
      end

      result
    end
  end

  defp joined, do: %{member: true, requested: false}

  defp do_join_group(current_user, group, circle, opts) do
    membership = Bonfire.Boundaries.Presets.membership_slug(group)
    skip? = Keyword.get(opts, :skip_boundary_check, false)

    if membership == "invite_only" and not skip? do
      {:error, :invite_only}
    else
      opts =
        if membership == "on_request" and not skip? do
          Keyword.put_new(opts, :to_feeds, notifications: [group | moderators(group)])
        else
          opts
        end

      case Bonfire.Social.Graph.Follows.follow(current_user, group, opts) do
        {:ok, %Bonfire.Data.Social.Follow{}}
        when membership in ["open", "local:members", "archipelago:members"] or skip? ->
          Bonfire.Boundaries.Circles.add_to_circles(current_user, circle)
          {:ok, joined()}

        {:ok, _request} ->
          {:ok, %{member: false, requested: true}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Accept a pending join request for a group. Wraps `Follows.accept/1` and adds the requester to the group's members circle.
  """
  def accept_join_request(admin, request_or_id, opts \\ []) do
    accept_opts = Keyword.merge([current_user: admin, skip_boundary_check: true], opts)

    with {:ok, follow} <-
           Bonfire.Social.Graph.Follows.accept(request_or_id, accept_opts),
         requester = e(follow, :edge, :subject, nil) || e(follow, :edge, :subject_id, nil),
         group = e(follow, :edge, :object, nil) || e(follow, :edge, :object_id, nil),
         {:ok, group} <-
           if(group,
             do: maybe_fetch_with_verb(admin, :mediate, group),
             else: error(follow, "Could not find matching group")
           ),
         {:ok, circle} <- members_circle(group) do
      if requester do
        with {:error, _} = err <- Bonfire.Boundaries.Circles.add_to_circles(requester, circle) do
          err
        else
          _ ->
            # subject is the requester, not the admin
            maybe_pin_to_sidebar(requester, group)
            {:ok, %{member: true, requested: false}}
        end
      else
        error(follow, "Could not find requester from follow request")
      end
    end
  end

  @doc "Leave a group, unfollowing and removing from the members circle."
  def leave_and_unfollow_group(current_user, group_or_id, opts \\ []) do
    with {:ok, _group} <- leave_group(current_user, group_or_id, opts) do
      Bonfire.Social.Graph.Follows.unfollow(current_user, group_or_id, opts)
      {:ok, %{member: false, requested: false, following: false}}
    end
  end

  @doc "Leave a group, unfollowing and removing from the members circle."
  def leave_group(current_user, group_or_id, opts \\ [])

  def leave_group(current_user, id, opts) when is_binary(id) do
    with {:ok, group} <- maybe_fetch(id, current_user: current_user) do
      leave_group(current_user, group, opts)
    end
  end

  def leave_group(current_user, group, opts) do
    with {:ok, circle} <- members_circle(group) do
      Bonfire.Boundaries.Circles.remove_from_circles(current_user, [circle])
      # leaving also unpins (removes from sidebar)
      Utils.maybe_apply(Bonfire.Social.Pins, :unpin, [current_user, group],
        current_user: current_user
      )

      {:ok, %{member: false, requested: false}}
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

  @doc "Add a user to a group's members circle (moderator/admin only)."
  def add_member(admin, group_or_id, user_or_id, opts \\ []) do
    with {:ok, group} <- maybe_fetch_with_verb(admin, :mediate, group_or_id),
         {:ok, user} <- Bonfire.Common.Needles.get(user_or_id, current_user: admin),
         # preload `character.peered` so the boundary checks below (member_role -> can?) classify
         # the member's locality without an on-demand (raising) preload
         user = repo().maybe_preload(user, character: [:peered]),
         {:ok, circle} <- members_circle(group) do
      Bonfire.Boundaries.Circles.add_to_circles(user, circle)
      maybe_pin_to_sidebar(user, group)
      {:ok, %{member: true, role: member_role(user, group)}}
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
  Promote a user to moderator of a group (moderator/admin only).

  Grants the `:moderate` role to the group's *moderators circle*, then
  adds the user to that circle. Because the grant is on the circle, every member of it inherits `:mediate` automatically, so promoting is just circle membership.
  """
  def add_moderator(admin, group_or_id, user_or_id, _opts \\ []) do
    with {:ok, group} <- maybe_fetch_with_verb(admin, :mediate, group_or_id),
         {:ok, user} <- Bonfire.Common.Needles.get(user_or_id, current_user: admin),
         # preload `character.peered` so the boundary checks below (member_role -> can?) classify
         # the member's locality without an on-demand (raising) preload
         user = repo().maybe_preload(user, character: [:peered]),
         {:ok, circle} <- moderators_circle(group) do
      # empower the circle on the group (no-op if already granted)
      Bonfire.Boundaries.Controlleds.grant_role(circle, group, :moderate,
        current_user: admin,
        scope: group
      )

      Bonfire.Boundaries.Circles.add_to_circles(user, circle)
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
      {:ok, true}
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
      p when p in ["open", "local:members", "archipelago:members"] ->
        "free"

      p when p in ["visible", "on_request"] ->
        "request"

      p when p in ["private", "invite_only"] ->
        "invite"

      other ->
        debug(other, "other preset_boundary")
        "free"
    end
  end

  def join_mode({preset_boundary, _name}) when is_binary(preset_boundary) do
    join_mode(preset_boundary)
  end

  def join_mode(group) do
    group
    |> Bonfire.Boundaries.Presets.membership_slug()
    |> tap(&info(&1, "join_mode: detected membership slug"))
    |> join_mode()
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
      {Bonfire.Classify.Categories, :join_group, [id(group_or_id), [skip_boundary_check: true]]}

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

  # Single-query fetch+authz: passes verb: to get/2 when fetching by ID; when a struct is
  # already available, falls back to a separate can? check to avoid a redundant DB round-trip.
  defp maybe_fetch_with_verb(user, verb, %{id: _} = group) do
    if Bonfire.Boundaries.can?(user, verb, group),
      do: {:ok, group},
      else: {:error, :not_permitted}
  end

  defp maybe_fetch_with_verb(user, verb, id) when is_binary(id) do
    get(id, current_user: user, verb: verb)
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

  @doc """
  Restores an archived (soft-deleted) group: clears `deleted_at` and re-indexes it.
  Inverse of `soft_delete/2`, gated by the same `ensure_update_allowed/2`.
  """
  def unarchive(%Category{} = c, user) do
    if Classify.ensure_update_allowed(user, c) do
      repo().transact_with(fn ->
        with {:ok, c} <- Bonfire.Common.Repo.Delete.undelete(c) do
          maybe_apply(Bonfire.Search, :maybe_index, [c, nil, user], user)
          {:ok, c}
        else
          e ->
            {:error, e}
        end
      end)
    else
      error("Sorry, you cannot restore this.")
    end
  end

  def unarchive(id, user) when is_binary(id) do
    # include soft-deleted rows; permission enforced by the struct clause
    with {:ok, c} <- get(id, [[:default_incl_deleted], skip_boundary_check: true]) do
      unarchive(c, user)
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

  # returns the updated Category, NOT an actor (unlike `update_local_actor/2`, whose caller is the AP library): callers here are Bonfire-side and thread the local object onwards — `create_remote_actor/1` for one uses the result as the character it returns
  def update_remote_actor(%Category{} = cat, params) do
    {declarations, params} = Map.pop(params, :remote_declarations)

    with {:ok, cat} <- __MODULE__.update(:skip_boundary_check, cat, params, false) do
      reapply_remote_declarations(cat, declarations)
      {:ok, cat}
    end
  end

  # A remote group's own declarations change over time: moderators come and go, and a community can flip `postingRestrictedToMods` or start requiring approval. Applying these only at creation would leave our mirror asserting whatever it declared the day we first saw it, which for the two flags means our boundaries drift out of step with the real community's rules. Lemmy re-syncs its moderators on every fetch for the same reason.
  defp reapply_remote_declarations(_cat, nil), do: :ok

  defp reapply_remote_declarations(cat, %{} = declarations) do
    sync_remote_moderators(cat, declarations[:attributed_to])

    Bonfire.Classify.Boundaries.apply(
      cat,
      nil,
      remote_dims(declarations)
    )
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
  Handles a change to who moderates a community, which arrives as an `Add` or `Remove` targeting the collection the community's `attributedTo` names.

  Applied as a RE-SYNC of that collection rather than as a delta: idempotent, self-correcting after a delivery we missed, and what we end up asserting is what the origin publishes rather than what an activity claimed. Lemmy itself re-syncs its whole list on every fetch.

  Two things are verified first, and both matter. The community must DECLARE the targeted collection as its own, since a collection cannot say whose it is (all three we captured are a bare `OrderedCollection`), so the group's own `attributedTo` is the only link and an activity naming an unrelated community fails it. And the actor must have authority over that community, because otherwise a stranger could make us re-fetch on demand even though the state we adopt is the origin's.
  """
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
