defmodule Bonfire.Classify.Web.JoinButtonLive do
  @moduledoc """
  Join/leave button for groups. Handles group membership (members circle) separately from
  following the group's feed. Shows an optional follow/unfollow toggle for the feed once
  the user is a member (or for open groups).
  """
  use Bonfire.UI.Common.Web, :stateful_component

  alias Bonfire.UI.Social.Graph.FollowButtonLive

  prop object_id, :string, default: nil
  prop object_name, :any, default: nil
  prop membership, :string, default: "on_request"
  prop path, :any, default: nil

  # nil = loading, false = not member, :requested = pending, true = member
  prop my_membership, :any, default: nil

  # optional follow state for the feed (passed through to embedded FollowButtonLive)
  prop my_follow, :any, default: nil

  prop moderators, :any, default: []

  prop container_class, :css_class, default: "flex flex-col items-stretch gap-2 w-full"
  prop class, :css_class, default: nil
  prop disabled, :boolean, default: false
  prop hide_icon, :boolean, default: false
  prop hide_text, :boolean, default: false
  prop showing_within, :any, default: nil

  def update_many(assigns_sockets),
    do: Bonfire.Classify.LiveHandler.update_many(assigns_sockets, caller_module: __MODULE__)

  defp set_clone_context({_, o}) do
    [{:clone_context, o}]
  end

  defp set_clone_context(%{id: id}) do
    [{:clone_context, id}]
  end

  defp set_clone_context(other) do
    warn(other, "cannot clone_context, expected a tuple or a map with an ID")
    []
  end
end
