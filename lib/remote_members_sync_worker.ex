# Commented out: the generic fetch job does this now. `ActivityPub.Federator.Workers.RemoteFetcherWorker`, op `fetch_collection`, reads the collection as the user it carries and hands its items to the adapter's `handle_remote_collection/2`, which routes them to `Bonfire.Classify.Categories.handle_remote_collection/2`. Kept for the record:
#
# defmodule Bonfire.Classify.RemoteMembersSyncWorker do
#   @moduledoc """
#   Copies the member list of a group hosted elsewhere into its mirror's members circle (`Bonfire.Classify.Categories.sync_remote_members/2`), in the background because it reads the origin's collection page by page and fetches every person it names that is not yet known here.
#
#   On the queue of the other background fetches. One job per group at a time, and one attempt: a read that fails leaves the mirror unchanged, and the next accepted join of one of ours there reads again.
#   """
#   use Oban.Worker,
#     queue: :remote_fetcher,
#     max_attempts: 1,
#     unique: [fields: [:args], keys: [:group_id]]
#
#   @doc "Queues the copy of `group`'s members, read as `joiner`, one of ours who is a member of it."
#   def enqueue(group, joiner) do
#     %{"group_id" => Bonfire.Common.Enums.id(group), "joiner_id" => Bonfire.Common.Enums.id(joiner)}
#     |> new()
#     |> Bonfire.Common.TestInstanceRepo.oban_insert()
#   end
#
#   @impl Oban.Worker
#   def perform(%Oban.Job{args: %{"group_id" => group_id, "joiner_id" => joiner_id}}) do
#     Bonfire.Classify.Categories.sync_remote_members(group_id, joiner_id)
#   end
# end
