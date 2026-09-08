if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupModeratorsCollectionTest do
    @moduledoc """
    A group publishes its mod team as `attributedTo`, so remote software can say who speaks for it.

    Lemmy, PieFed, NodeBB and Mbin all point `attributedTo` at a moderators collection and dereference it, and 1b12's convention for accepting moderation is "the actor is mod-listed OR same-origin as the group" — so the list is what lets OUR moderators act from THEIR own instances. We already read a remote community's list (`Categories.sync_remote_moderators/3`); this is the other half.

    **Publication follows the group's visibility, and the circle IS the list.** The moderators are already public for any group whose page a guest can see: `Categories.moderators/1` takes no `current_user` and applies no boundary check, and the About tab renders them. So publishing restates what the web already gives, rather than exposing anything new, and needs no per-moderator opt-in — being in the moderators circle is the choice. Someone who should moderate without being listed gets the role granted directly instead, which boundaries already support and `group_dimension_narrowing_test.exs` already relies on.

    Serving it as a collection URI rather than an inline array is what keeps removal meaningful: taking someone off changes what the endpoint returns, and Lemmy re-syncs on every fetch.
    """
    use Bonfire.Classify.ConnCase, async: false
    use Bonfire.Common.Utils

    alias Bonfire.Classify.Categories

    defp public_group(creator) do
      group = fake_group!(creator)

      assert :ok =
               Bonfire.Classify.Boundaries.apply(group, creator, %{
                 membership: "open",
                 visibility: "global",
                 participation: "anyone",
                 default_content_visibility: "public"
               })

      {:ok, group} = Categories.get(id(group), skip_boundary_check: true)
      group
    end

    defp actor_data(group) do
      assert %{data: data} = Categories.format_actor(group)
      data
    end

    test "a group's actor points at its moderators collection" do
      creator = Bonfire.Me.Fake.fake_user!()
      group = public_group(creator)

      assert actor_data(group)["attributedTo"] ==
               ActivityPub.Utils.collection_ap_id("moderators", id(group)),
             "a URI rather than an inline list, so removing a moderator changes what the endpoint serves instead of being stuck in every remote's cache"
    end

    test "the collection lists the group's moderators" do
      creator = Bonfire.Me.Fake.fake_user!()
      mod = Bonfire.Me.Fake.fake_user!()
      group = public_group(creator)

      assert {:ok, _} = Categories.add_moderator(creator, group, id(mod))

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/collections/moderators/#{id(group)}")

      assert %{"type" => "OrderedCollection", "orderedItems" => items} = json_response(conn, 200)

      refute Map.has_key?(json_response(conn, 200), "first"),
             "Lemmy and PieFed read `orderedItems` from the top level and never follow pages, and both of our captures of their own moderators collections are flat — paged, ours reads as empty"

      # matched on the moderator's own id rather than a recomputed canonical URL: building one here from a non-preloaded user takes a different path than the serving code does, so a mismatch would be about preloads rather than about membership
      assert Enum.any?(items, &String.contains?(&1, id(mod))),
             "1b12 receivers accept moderation when the actor is mod-listed, so a moderator missing here cannot act for this group from their own instance. Got: #{inspect(items)}"
    end

    # The half that keeps publication honest: a group whose page does not show its moderators must not publish them either, or the wire says more than the web does.
    test "a members-only group does not publish its moderators" do
      creator = Bonfire.Me.Fake.fake_user!()
      group = fake_group!(creator)

      assert :ok =
               Bonfire.Classify.Boundaries.apply(group, creator, %{
                 membership: "invite_only",
                 visibility: "members:private",
                 participation: "group_members",
                 default_content_visibility: "members:private"
               })

      {:ok, group} = Categories.get(id(group), skip_boundary_check: true)

      refute actor_data(group)["attributedTo"],
             "publishing follows the group's own visibility, so a group that hides its members must not name its moderators to the fediverse"
    end
  end
end
