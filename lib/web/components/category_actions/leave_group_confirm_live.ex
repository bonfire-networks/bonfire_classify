defmodule Bonfire.Classify.Web.LeaveGroupConfirmLive do
  @moduledoc """
  Confirms leaving a group, so a stray click can't drop a membership that may take a moderator to restore.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  prop object_id, :string, required: true
  # the Join button that opened this, if one did (the hero's and the sidebar's Leave are not one): its id is sent back with the answer, else every Join button for the group is updated (`ComponentID`)
  prop button_id, :string, default: nil
  prop group_name, :string, required: true
  # see `Bonfire.Classify.Categories.join_mode/1`
  prop join_mode, :string, default: nil
end
