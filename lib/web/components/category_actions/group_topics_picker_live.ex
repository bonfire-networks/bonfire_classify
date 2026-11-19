defmodule Bonfire.Classify.Web.GroupTopicsPickerLive do
  @moduledoc """
  The modal offered after following, belling, unfollowing or un-belling a group: its topics with a checkbox each, none ticked (all ticked in `:boundaries` mode, offered to a moderator after saving the group's boundary settings), and a toggle to tick or untick them all. The group's own action has already taken effect, so closing it loses nothing.

  One component for the four `mode`s (`Bonfire.Classify.Categories.topic_choices/3`), since only the label and the action per ticked topic differ. Opened with `open/4`, which asks `topic_choices/3` once and shows nothing when there are no topics to offer.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  @doc "The group whose topics are offered."
  prop group_id, :string, required: true

  @doc "`:follow`, `:bell`, `:unfollow`, `:unbell`, or `:boundaries` (the one mode whose checkboxes start ticked)."
  prop mode, :atom, required: true

  @doc "The topics offered, as `Bonfire.Classify.Categories.topic_choices/3` returns them."
  prop topics, :list, default: []

  @doc "Ids of the topics already on, shown with their Follow (or bell) button in its on state, so they can be turned off from here."
  prop on_ids, :list, default: []

  @doc "Ids of the topics that must be followed before they can be rung: shown with the Follow button and a locked checkbox, which unlocks once followed."
  prop needs_follow_ids, :list, default: []

  @doc """
  Opens the modal for this person and group, unless there is no topic to offer (then nothing happens). One `topic_choices/3` query, done here rather than in the modal so that deciding whether to show it and showing it don't ask twice.
  """
  def open(user, group, mode, modal_id \\ nil) do
    case Bonfire.Classify.Categories.topic_choices(user, group, mode) do
      %{topics: [_ | _] = topics, on_ids: on_ids, needs_follow_ids: needs_follow_ids} ->
        Bonfire.UI.Common.ReusableModalLive.set(
          [
            show: true,
            title_text: title(mode),
            no_actions: true,
            modal_assigns: [
              modal_component: __MODULE__,
              modal_component_stateful?: true,
              group_id: id(group),
              mode: mode,
              topics: topics,
              on_ids: on_ids,
              needs_follow_ids: needs_follow_ids
            ]
          ],
          modal_id
        )

        :open

      _ ->
        :none
    end
  end

  def title(:follow), do: l("Follow some of its topics too?")
  def title(:bell), do: l("Be notified about some of its topics too?")
  def title(:unfollow), do: l("Unfollow some of its topics too?")
  def title(:unbell), do: l("Stop notifications for some of its topics too?")
  def title(:boundaries), do: l("Apply the new settings to its topics too?")

  def submit_label(:boundaries), do: l("Apply")
  def submit_label(:follow), do: l("Follow")
  def submit_label(:bell), do: l("Notify me")
  def submit_label(:unfollow), do: l("Unfollow")
  def submit_label(:unbell), do: l("Stop notifying me")

  def topic_name(topic), do: e(topic, :profile, :name, nil) || l("Untitled topic")
end
