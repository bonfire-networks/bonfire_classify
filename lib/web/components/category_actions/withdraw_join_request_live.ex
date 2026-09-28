defmodule Bonfire.Classify.Web.WithdrawJoinRequestLive do
  @moduledoc """
  Confirmation content for withdrawing a join request in the shared modal.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  prop object_id, :string, required: true
  prop button_id, :string, required: true
  prop group_name, :string, required: true
  prop withdrawal_error, :string, default: nil
end
