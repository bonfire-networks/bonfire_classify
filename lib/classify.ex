defmodule Bonfire.Classify do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  import Untangle
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

    not is_nil(user) and
      ((user == :skip_boundary_check or
          Types.uid(user) ==
            (e(c, :creator, :id, nil) ||
               e(c, :created, :creator_id, nil))) ||
         Bonfire.Boundaries.can?(user, :edit, c))

    # TODO: add admin permission too?
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
      # |> flood("publllished1")
      {:ok, nil} ->
        {:ok, item}

      other ->
        Utils.maybe_apply(Bonfire.Social.Activities, :activity_under_object, [other])
    end

    # |> flood("publllished2")

    #   |> debug()
    # end
  end
end
