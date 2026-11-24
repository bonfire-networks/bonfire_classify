defmodule Bonfire.Classify.Routing do
  @moduledoc """
  Places a post published by a program (an import, a sync) into a group, or into a topic inside it.

  The caller names the target (a group or a topic, by id) and, for a group, which of its topics the post belongs in, by slug or name. The author is made a member of the group, and allowed to post in the topic, so the post reaches its feed.
  """
  use Bonfire.Common.Utils
  import Untangle
  alias Bonfire.Common.Enums
  alias Bonfire.Common.Text
  alias Bonfire.Classify.Categories

  @doc """
  Where a post goes: `{:topic, topic}`, `{:group, group}` or `{:no_context, nil}`.

  - `target_id` is a topic: that topic.
  - `target_id` is a group: its topic matching `topic_slug` (see `find_topic_in_group/2`), else the group.
  - no `target_id`: the topic whose username is `topic_slug`, in any group, else nowhere.
  """
  def resolve_context(target_id, topic_slug \\ nil)

  def resolve_context(target_id, topic_slug) when is_binary(target_id) do
    case Categories.get(target_id, skip_boundary_check: true) do
      {:ok, target} ->
        if topic?(target) do
          {:topic, target}
        else
          find_topic_in_group(target, topic_slug) || {:group, target}
        end

      _ ->
        {:no_context, nil}
    end
  end

  def resolve_context(nil, topic_slug) do
    case is_binary(topic_slug) && Categories.get(topic_slug, skip_boundary_check: true) do
      {:ok, topic} ->
        if topic?(topic), do: {:topic, topic}, else: {:no_context, nil}

      _ ->
        {:no_context, nil}
    end
  end

  def resolve_context(_, _topic_slug), do: {:no_context, nil}

  @doc """
  The topic of a loaded `group` matching `slug`: `{:topic, topic}`, or `nil`.

  It matches the topic's username first, then a name that slugifies to the same `slug`, only when exactly one does (a username can carry a suffix, and two names can slugify alike, so it doesn't guess).
  """
  def find_topic_in_group(group, slug) when is_binary(slug) do
    case Categories.one(
           [username: slug, parent_category: Enums.id(group), type: :topic],
           skip_boundary_check: true
         ) do
      {:ok, topic} -> {:topic, topic}
      _ -> find_topic_by_name_in_group(group, slug)
    end
  end

  def find_topic_in_group(_group, _slug), do: nil

  @doc """
  The topic of a loaded `group` for a category from elsewhere (eg. a WordPress category), `%{name:, slug:}`: found by its slug, else by its name (see `find_topic_in_group/2`). Returns `{:topic, topic}`, or `nil`.

  Both are tried since a topic made here from a category is named after it, while its username may differ from the category's slug (eg. it was taken).
  """
  def find_topic_for(group, %{} = category) do
    find_topic_in_group(group, category[:slug]) || find_topic_in_group(group, category[:name])
  end

  @doc """
  The topic of a loaded `group` for a category from elsewhere (`%{name:, slug:}`, see `find_topic_for/2`), made in the group by `creator` when there is none. Returns `{:ok, topic, :found | :created}`, or an error.
  """
  def get_or_create_topic_for(group, %{name: name} = category, creator)
      when is_binary(name) and name != "" do
    case find_topic_for(group, category) do
      {:topic, topic} ->
        {:ok, topic, :found}

      nil ->
        with {:ok, topic} <-
               Categories.create(creator, %{type: :topic, name: name, parent_category: group}) do
          {:ok, topic, :created}
        end
    end
  end

  def get_or_create_topic_for(_group, category, _creator),
    do: error(category, "A topic needs a name")

  defp find_topic_by_name_in_group(group, slug) do
    case find_topic_name_matches(group, Text.slug(slug)) do
      [topic] -> {:topic, topic}
      _ -> nil
    end
  end

  defp find_topic_name_matches(group, normalized_slug, after_cursor \\ nil, matches \\ []) do
    opts =
      [skip_boundary_check: true, limit: 500]
      |> maybe_put_after_cursor(after_cursor)

    page =
      Categories.list(
        [:default, parent_category: Enums.id(group), type: :topic],
        opts
      )

    matches =
      page
      |> e(:edges, [])
      |> Enum.reduce(matches, fn topic, matches ->
        case e(topic, :name, nil) do
          name when is_binary(name) and length(matches) < 2 ->
            if Text.slug(name) == normalized_slug, do: [topic | matches], else: matches

          _ ->
            matches
        end
      end)

    next_cursor = e(page, :page_info, :end_cursor, nil)
    has_next_page? = e(page, :page_info, :has_next_page, false)

    if length(matches) < 2 and has_next_page? and is_binary(next_cursor) and
         next_cursor != after_cursor do
      find_topic_name_matches(group, normalized_slug, next_cursor, matches)
    else
      matches
    end
  end

  defp maybe_put_after_cursor(opts, nil), do: opts
  defp maybe_put_after_cursor(opts, cursor), do: Keyword.put(opts, :after, cursor)

  @doc "The boundary for a post placed in `context` (a group or topic) when the source doesn't set one: as the group shares its posts, else public."
  def default_boundary(context),
    do:
      (context && Bonfire.Classify.Boundaries.read_default_content_visibility(context)) ||
        "public"

  @doc "The publish opts that place a post in `context` (a group or topic): its `context_id:`, and a mention of it so the post reaches its feed. None without a context."
  def publish_opts(context) do
    case context && Enums.id(context) do
      id when is_binary(id) -> [context_id: id, mentions: [id]]
      _ -> []
    end
  end

  @doc "Whether a category is a topic."
  def topic?(category), do: e(category, :type, nil) in [:topic, "topic"]

  @doc "`:ok`, or `{:error, :topic_required}` when a topic is required and the post resolved to something else."
  def check_topic_requirement(false, _context_type), do: :ok
  def check_topic_requirement(true, :topic), do: :ok
  def check_topic_requirement(true, _context_type), do: {:error, :topic_required}

  @doc """
  Whether `user` may have a program place their own posts anywhere in `group` (making them a member and allowing them to post in its topics, see `ensure_author_can_post/3`): someone who manages the group (`Bonfire.Classify.group_manager?/3`: its creator or moderators), or who moderates the instance (`:mediate` on `:instance`, as moderation checks elsewhere ask).
  """
  def may_join_to_post?(user, group) do
    not is_nil(user) and
      (Bonfire.Boundaries.can?(user, :mediate, :instance) == true or
         Bonfire.Classify.group_manager?(user, group) == true)
  end

  @doc """
  Makes `author` a member of the group (`group_id`, else `context`) and allows it to post in `context`, so a post it publishes there reaches the feed. Idempotent. Always `:ok`: a failure is warned, and the post is still published.
  """
  def ensure_author_can_post(_author, nil, _group_id), do: :ok

  # TODO: joining a *group* grants `:tag` (its members circle gets `:contribute`), but joining a *topic* grants nothing (a topic never wires its own members circle into its ACL), so the explicit grant below is needed. Cleaner fix would be at the source in bonfire_classify — have topics grant their own members circle `:contribute` — so "join → can participate" holds uniformly.
  def ensure_author_can_post(author, context, group_id) do
    target = group_id || Enums.id(context)

    case Categories.join_and_follow_group(author, target, skip_boundary_check: true) do
      {:ok, _} ->
        :ok

      other ->
        warn(other, "Could not add import author to group/topic — post may not reach its feed")
    end

    # Membership alone can't tag a *topic* (grant goes to the parent group's members circle, not the topic's own — see `init_boundaries`), so the auto-boost silently no-ops. Grant `:contribute` (includes `:tag`) directly. Idempotent; no-op once the author already has tag permission.
    # On `context`, not `target`: a group `target` can resolve to a child topic, and the boost needs `:tag` on that topic — `can?(:tag, target)` could pass via group membership while it can't.
    maybe_grant_tag_permission(author, Enums.id(context) || target)

    :ok
  end

  defp maybe_grant_tag_permission(author, object) do
    if Bonfire.Boundaries.can?(author, :tag, object) do
      :ok
    else
      Bonfire.Boundaries.Controlleds.grant_role(author, object, :contribute,
        current_user: author,
        skip_boundary_check: true
      )

      :ok
    end
  rescue
    e ->
      warn(e, "Could not grant :contribute to import author — post may not reach the topic feed")
      :ok
  end

  @doc """
  Boosts an already-published `post` into the feed of `context` (a group or topic), after `ensure_author_can_post/3` unless `join: false` (for an author who may only post where they already can). Idempotent and best-effort: always `:ok`. `opts[:auto_boost_at]` dates the boost (eg. when the post was first published).
  """
  def boost_into_context(author, context, post, group_id, opts \\ [])

  def boost_into_context(author, {context_type, context}, post, group_id, opts)
      when context_type in [:topic, :group] and not is_nil(context) do
    if Keyword.get(opts, :join, true), do: ensure_author_can_post(author, context, group_id)

    Bonfire.Social.Tags.maybe_auto_boost(author, context, post, Keyword.delete(opts, :join))
    :ok
  rescue
    e ->
      warn(e, "Could not route a published post into its group or topic feed")
      :ok
  end

  def boost_into_context(_author, _context, _post, _group_id, _opts), do: :ok
end
