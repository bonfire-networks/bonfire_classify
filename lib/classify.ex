defmodule Bonfire.Classify do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  import Untangle
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
      |> proload(edge: [object: [:tree]])
      |> debug("querry")
      |> repo().many_paginated(opts)

    followed_categories =
      followed
      |> e(:edges, [])
      |> Enum.map(fn f ->
        c = e(f, :edge, :object, %{})

        c
        |> Map.put(:path, e(c, :tree, :path, []))
      end)
      # |> debug("followed_categories")
      |> Tree.arrange()

    # |> debug("treee")

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
      (user == :skip_boundary_check or
         Types.ulid(user) ==
           (e(c, :creator, :id, nil) ||
              e(c, :created, :creator_id, nil)) ||
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

  def maybe_index(object) do
    if module =
         Extend.maybe_module(
           Bonfire.Search.Indexer,
           e(object, :creator, nil) ||
             e(object, :created, :creator_id, nil)
         ) do
      module.maybe_index_object(object)
    else
      :ok
    end
  end

  def maybe_unindex(object) do
    if module = Extend.maybe_module(Bonfire.Search.Indexer) do
      module.maybe_delete_object(object)
    else
      :ok
    end
  end

  def publish(creator, verb, item, attrs, for_module \\ __MODULE__) do
    # TODO: add bespoke AP callbacks to Categories?
    # if Extend.module_enabled?(ValueFlows.Util) and
    #      function_exported?(ValueFlows.Util, :publish, 4) do
    #   ValueFlows.Util.publish(creator, verb, item, attrs: attrs)
    #   |> debug()
    # else
    Utils.maybe_apply(Bonfire.Social.Objects, :publish, [
      creator,
      verb,
      item,
      attrs,
      for_module
    ])

    #   |> debug()
    # end
  end
end
