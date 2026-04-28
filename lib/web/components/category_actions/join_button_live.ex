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
  # nil (not "on_request") so update_many's preload runs when caller omits the prop
  prop membership, :string, default: nil
  prop path, :any, default: nil

  # nil = loading, false = not member, :requested = pending, true = member
  prop my_membership, :any, default: nil

  # optional follow state for the feed (passed through to embedded FollowButtonLive)
  prop my_follow, :any, default: nil

  prop moderators, :any, default: []

  prop container_class, :css_class, default: "flex flex-1 gap-2 w-full"
  prop class, :css_class, default: nil
  prop disabled, :boolean, default: false
  prop hide_icon, :boolean, default: false
  prop hide_text, :boolean, default: false
  prop showing_within, :any, default: nil

  # Memberships where Follow is the natural action — used both to decide whether
  # to show the inner Follow button and whether the wrapper needs layout space.
  # `invite_only` is here because announcement channels surface Follow (not Join)
  # as the primary action.
  @follow_eligible_memberships ~w(open local:members archipelago:members invite_only)

  def follow_eligible?(membership), do: membership in @follow_eligible_memberships

  def inner_follow_visible?(my_membership, membership, showing_within) do
    showing_within != :list and
      (my_membership == true or
         (follow_eligible?(membership) and my_membership != :requested))
  end

  # Wrapper layout space is needed when either the join branch or the inner
  # follow renders. Without this guard the empty wrapper claims `flex-1` space
  # in a flex-row parent and leaves a ghost cell next to a sibling button.
  def wrapper_visible?(my_membership, membership, showing_within) do
    join_button_visible?(my_membership, membership) or
      inner_follow_visible?(my_membership, membership, showing_within)
  end

  defp join_button_visible?(my_membership, membership) do
    my_membership != false or membership != "invite_only"
  end

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
