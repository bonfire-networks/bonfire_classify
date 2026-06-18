defmodule Bonfire.Classify do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  import Untangle
  import Ecto.Query
  use Arrows
  use Bonfire.Common.Repo
  use Bonfire.Common.E
  alias Bonfire.Common.Utils
  alias Bonfire.Common.Extend
  alias Bonfire.Common
  alias Common.Types
  alias Bonfire.Classify.Category
  alias Bonfire.Classify.Tree

  def my_followed_tree(current_user, opts) do
    followed =
      Bonfire.Social.Graph.Follows.list_my_followed(current_user,
        type: Category,
        return: :query
      )
      # `:settings` is preloaded so per-group lookups (e.g. `SidebarGroupsLive.group_icon/1`
      # reading `:preset_slug`) don't issue N+1 queries when iterating the result.
      |> proload(edge: [object: [:tree, :settings]])
      |> debug("querry")
      |> repo().many_paginated(opts)

    # Soft-deleted categories are skipped — the follow relationship persists past
    # `Categories.soft_delete/2` (we don't tear down circle/follow state on delete),
    # so without this filter they'd linger in the sidebar.
    followed_categories =
      for f <- e(followed, :edges, []),
          c = e(f, :edge, :object, %{}),
          is_nil(e(c, :deleted_at, nil)) do
        Map.put(c, :path, e(c, :tree, :path, []))
      end
      |> Tree.arrange()

    {followed_categories, e(followed, :page_info, [])}
  end

  @doc """
  The user's pinned groups for the groups sidebar, as a flat ordered `[{category, []}]` list.
  Pin (not follow/bookmark) drives sidebar visibility. Admin-curated instance pins come first, in
  the admin-set order (`Pins.rank_pin(_, :instance, _)`), followed by the user's own pins.
  """
  def my_pinned_tree(current_user) do
    # flat (the sidebar template ignores nesting), [instance-ranked ++ user] order, in one query
    current_user
    |> Bonfire.Social.Pins.sidebar_pinned_object_ids()
    |> load_categories_ordered()
    |> Enum.map(&{&1, []})
  end

  @doc "Instance-pinned groups in admin order (`Pins.rank_pin(_, :instance, _)`), for the admin reorder UI."
  def instance_pinned_groups,
    do: Bonfire.Social.Pins.instance_pinned_object_ids() |> load_categories_ordered()

  # load the given group ids preserving order, dropping archived ones. A pin persists past
  # `soft_delete/2` (Category has its OWN `deleted_at`, not the pointer's). One query: `:character`
  # and `:profile`/`:icon` are joined via proload too (no separate maybe_preload round-trips).
  defp load_categories_ordered([]), do: []

  defp load_categories_ordered(ids) do
    by_id =
      from(c in Category, where: c.id in ^ids and is_nil(c.deleted_at))
      |> proload([:tree, :settings, :character, profile: [:icon]])
      |> repo().many()
      |> Map.new(&{&1.id, &1})

    ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  @doc """
  Lists the current user's archived (soft-deleted) groups they're allowed to restore.

  Reuses the same follow-based source as the sidebar (follows persist past `soft_delete/2`),
  keeping only soft-deleted groups the user can update.
  """
  def my_archived_groups(current_user, opts \\ []) do
    followed =
      Bonfire.Social.Graph.Follows.list_my_followed(current_user,
        type: Category,
        return: :query
      )
      # `list_my_followed` already binds profile + character, so only add the extras
      |> proload(edge: [object: [:tree, :settings]])
      |> repo().many_paginated(Keyword.put_new(opts, :limit, 100))

    archived =
      for f <- e(followed, :edges, []),
          c = e(f, :edge, :object, %{}),
          not is_nil(e(c, :deleted_at, nil)),
          ensure_update_allowed(current_user, c) do
        Map.put(c, :path, e(c, :tree, :path, []))
      end

    {archived, e(followed, :page_info, [])}
  end

  def arrange_categories_tree(categories) do
    categories
    |> Enum.map(fn c ->
      c
      |> Map.put(:path, e(c, :tree, :path, []))
    end)
    |> Tree.arrange()
  end

  def ensure_update_allowed(user, c) do
    # debug(user)

    # moderators (`:mediate`) can also manage group settings (e.g. moderators)
    not is_nil(user) and
      ((user == :skip_boundary_check or
          Types.uid(user) ==
            (e(c, :creator, :id, nil) ||
               e(c, :created, :creator_id, nil))) ||
         Bonfire.Boundaries.can?(user, :edit, c) ||
         Bonfire.Boundaries.can?(user, :mediate, c))
  end

  # def ensure_delete_allowed(user, c) do
  #   if user.local_user.is_instance_admin or user.id == ((c, :creator, :id, nil) || (c, :created, :creator_id, nil)) do
  #     :ok
  #   else
  #     GraphQL.not_permitted("to delete this")
  #   end
  # end

  def publish(creator, verb, item, attrs, for_module \\ __MODULE__) do
    # TODO: add bespoke AP callbacks to Categories?
    # if Extend.module_enabled?(ValueFlows.Util) and
    #      function_exported?(ValueFlows.Util, :publish, 4) do
    #   ValueFlows.Util.publish(creator, verb, item, attrs: attrs)
    #   |> debug()
    # else
    case Utils.maybe_apply(Bonfire.Social.Objects, :publish, [
           creator,
           verb,
           item,
           attrs,
           for_module
         ]) do
      # |> debug("publllished1")
      {:ok, nil} ->
        {:ok, item}

      other ->
        Utils.maybe_apply(Bonfire.Social.Activities, :activity_under_object, [other])
    end

    # |> debug("publllished2")

    #   |> debug()
    # end
  end
end
