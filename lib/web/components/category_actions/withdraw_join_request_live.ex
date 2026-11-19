defmodule Bonfire.Classify.Web.WithdrawJoinRequestLive do
  @moduledoc """
  Confirmation content for withdrawing a join request in the shared modal.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  prop object_id, :string, required: true

  # the Join button that opened this: its id is sent back with the answer, else every Join button for the group is updated (`ComponentID`)
  prop button_id, :string, default: nil
  prop group_name, :string, required: true
  prop withdrawal_error, :string, default: nil
end
