defmodule Bonfire.Classify.FeedFilters do
  @moduledoc """
  Narrows a feed to the activities in the outboxes of groups and their topics, which is what the group pages show, so the "My groups" and "All known groups" presets are one filter each.

  `in_groups: :all` keeps every group and topic this instance knows, local or mirrored, and `in_groups: :joined` the groups the viewer is a member of and their topics. An origin beside the scope, eg. `[:all, :remote]`, keeps the groups and topics hosted here (`:local`) or mirrored from elsewhere (`:remote`), each by its own `peered`. `in_groups: :feed_ids` says the groups' outboxes are already given in `feed_ids`, and adds nothing, so a caller holding them can replace a preset's `:joined`. The others are each one `feed_id IN (subquery)` built by `Bonfire.Classify.Categories.group_outbox_ids_query/2`, so nothing is listed in Elixir and nothing needs refreshing when someone joins or leaves. Who may see each activity is still decided by the feed's usual per-activity checks.

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

  # one clause for the whole list, a scope and an optional origin (eg. `[:all, :remote]`), so there is one subquery per page
  def maybe_filter(query, {:in_groups, in_groups}, opts) do
    {scope, origin} = scope_and_origin(in_groups)

    case {scope, current_user(opts)} do
      {nil, _} ->
        query

      # the caller already gives the groups' outboxes as `feed_ids` (as /groups does with the ones it holds), so no subquery is needed
      {:feed_ids, _} ->
        query

      {:joined, nil} ->
        # nobody to have joined anything, so there is nothing to show
        where(query, false)

      {:joined, user} ->
        where(
          query,
          [main_object: fp],
          fp.feed_id in subquery(Categories.group_outbox_ids_query({:joined, user}, origin))
        )

      {:all, _} ->
        where(
          query,
          [main_object: fp],
          fp.feed_id in subquery(Categories.group_outbox_ids_query(:all, origin))
        )
    end
  end

  def maybe_filter(query, _filter, _opts), do: query

  # a bare scope, as the presets and saved filters have it, is a one-item list
  defp scope_and_origin(in_groups) do
    values = in_groups |> List.wrap() |> Enum.map(&to_string/1)

    scope =
      cond do
        "feed_ids" in values -> :feed_ids
        "joined" in values -> :joined
        "all" in values -> :all
        true -> nil
      end

    origin =
      cond do
        "local" in values -> :local
        "remote" in values -> :remote
        true -> nil
      end

    {scope, origin}
  end
end
