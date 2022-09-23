defmodule Bonfire.Classify do
  import Untangle
  alias Bonfire.Common.Utils

  def ensure_update_allowed(user, c) do
    not is_nil(user) and
      (Utils.ulid(user) ==
         (Utils.e(c, :creator, :id, nil) ||
            Utils.e(c, :created, :creator_id, nil)) ||
         Bonfire.Boundaries.can?(user, :edit, c))

    # TODO: add admin permission too?
  end

  # def ensure_delete_allowed(user, c) do
  #   if user.local_user.is_instance_admin or user.id == ((c, :creator, :id, nil) || (c, :created, :creator_id, nil)) do
  #     :ok
  #   else
  #     GraphQL.not_permitted("delete")
  #   end
  # end

  def maybe_index(object) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_index_object(object)
    else
      :ok
    end
  end

  def maybe_unindex(object) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_delete_object(object)
    else
      :ok
    end
  end

  def publish(creator, verb, item, attrs, for_module \\ __MODULE__) do
    if function_exported?(ValueFlows.Util, :publish, 3) do
      ValueFlows.Util.publish(creator, verb, item, attrs: attrs)
    else
      Utils.maybe_apply(Bonfire.Social.Objects, :publish, [
        creator,
        verb,
        item,
        attrs,
        for_module
      ])
    end
  end
end
