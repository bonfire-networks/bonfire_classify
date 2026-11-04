defmodule Bonfire.Classify.FeedFilters do
  @moduledoc """
  Narrows a feed to the activities in the outboxes of groups and their topics, which is what the group pages show, so the "My groups" and "All known groups" presets are one filter each.

  `in_groups: :all` keeps every group and topic this instance knows, local or mirrored, and `in_groups: :joined` the groups the viewer is a member of and their topics. Each is one `feed_id IN (subquery)` built by `Bonfire.Classify.Categories.group_outbox_ids_query/1`, so nothing is listed in Elixir and nothing needs refreshing when someone joins or leaves. Who may see each activity is still decided by the feed's usual per-activity checks.

  Lives here rather than in the feed loader because groups, topics and their membership are this extension's. The key is declared as a field on `Bonfire.Social.FeedFilters` from this extension's config, and this module applies it; `Bonfire.Common.FeedFilterModule` explains why the two halves are declared in different places.
  """
  use Bonfire.Common.Utils, only: [current_user: 1]
  use Bonfire.Common.Repo

  alias Bonfire.Classify.Categories

  @behaviour Bonfire.Common.FeedFilterModule

  @impl true
  def feed_filter_module, do: __MODULE__

  @impl true
  def maybe_filter(query, filter, opts \\ [])

  def maybe_filter(query, {:in_groups, :all}, _opts) do
    where(
      query,
      [main_object: fp],
      fp.feed_id in subquery(Categories.group_outbox_ids_query(:all))
    )
  end

  def maybe_filter(query, {:in_groups, :joined}, opts) do
    case current_user(opts) do
      nil ->
        # nobody to have joined anything, so there is nothing to show
        where(query, false)

      user ->
        where(
          query,
          [main_object: fp],
          fp.feed_id in subquery(Categories.group_outbox_ids_query({:joined, user}))
        )
    end
  end

  def maybe_filter(query, _filter, _opts), do: query
end
