defmodule Bonfire.Classify do
  import Untangle
  alias Bonfire.Common.Utils

  def ensure_update_allowed(user, c) do
    not is_nil(user) and (
      Utils.ulid(user) == (Utils.e(c, :creator, :id, nil) || Utils.e(c, :created, :creator_id, nil))
      ||
      Bonfire.Boundaries.can?(user, :edit, c)
    )  # TODO: add admin permission too?
  end

  # def ensure_delete_allowed(user, c) do
  #   if user.local_user.is_instance_admin or user.id == ((c, :creator, :id, nil) || (c, :created, :creator_id, nil)) do
  #     :ok
  #   else
  #     GraphQL.not_permitted("delete")
  #   end
  # end
end
