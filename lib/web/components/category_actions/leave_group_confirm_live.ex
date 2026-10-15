defmodule Bonfire.Classify.Web.LeaveGroupConfirmLive do
  @moduledoc """
  Confirms leaving a group, so a stray click can't drop a membership that may take a moderator to restore.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  prop object_id, :string, required: true
  prop button_id, :string, required: true
  prop group_name, :string, required: true
  # see `Bonfire.Classify.Categories.join_mode/1`
  prop join_mode, :string, default: nil
end
