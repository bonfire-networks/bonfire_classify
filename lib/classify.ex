defmodule Bonfire.Classify do
  import Untangle
  use Bonfire.Common.Repo
  alias Bonfire.Common.Utils
  alias Bonfire.Common.Extend
  alias Bonfire.Common
  alias Common.Types
  alias Bonfire.Classify.Category
  alias Bonfire.Classify.Tree

  def my_followed_tree(current_user, opts) do
    followed =
      Bonfire.Social.Follows.list_my_followed(current_user,
        type: Category,
        return: :query
      )
      |> proload(edge: [object: [:tree]])
      |> debug("querry")
      |> repo().many_paginated(opts)

    followed_categories =
      followed
      |> Utils.e(:edges, [])
      |> Enum.map(fn f ->
        c = Utils.e(f, :edge, :object, %{})

        c
        |> Map.put(:path, Utils.e(c, :tree, :path, []))
      end)
      |> debug("followed_categories")
      |> Tree.arrange()
      |> debug("treee")

    {followed_categories, Utils.e(followed, :page_info, [])}
  end

  def ensure_update_allowed(user, c) do
    not is_nil(user) and
      (Types.ulid(user) ==
         (Utils.e(c, :creator, :id, nil) ||
            Utils.e(c, :created, :creator_id, nil)) ||
         is_admin?(user) ||
         Bonfire.Boundaries.can?(user, :edit, c))

    # TODO: add admin permission too?
  end

  def is_admin?(user) do
    if is_map(user) and Map.get(user, :instance_admin) do
      Map.get(user.instance_admin, :is_instance_admin)
    else
      # FIXME
      false
    end
  end

  # def ensure_delete_allowed(user, c) do
  #   if user.local_user.is_instance_admin or user.id == ((c, :creator, :id, nil) || (c, :created, :creator_id, nil)) do
  #     :ok
  #   else
  #     GraphQL.not_permitted("delete")
  #   end
  # end

  def maybe_index(object) do
    if Extend.module_enabled?(
         Bonfire.Search.Indexer,
         Utils.e(object, :creator, :id, nil) ||
           Utils.e(object, :created, :creator_id, nil)
       ) do
      Bonfire.Search.Indexer.maybe_index_object(object)
    else
      :ok
    end
  end

  def maybe_unindex(object) do
    if Extend.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_delete_object(object)
    else
      :ok
    end
  end

  def publish(creator, verb, item, attrs, for_module \\ __MODULE__) do
    # TODO: add bespoke AP callbacks to Categories?
    if Extend.module_enabled?(ValueFlows.Util) and
         function_exported?(ValueFlows.Util, :publish, 4) do
      ValueFlows.Util.publish(creator, verb, item, attrs: attrs)
      |> debug()
    else
      Utils.maybe_apply(Bonfire.Social.Objects, :publish, [
        creator,
        verb,
        item,
        attrs,
        for_module
      ])
      |> debug()
    end
  end
end
