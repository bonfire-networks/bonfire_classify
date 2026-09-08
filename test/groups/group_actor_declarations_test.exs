if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupActorDeclarationsTest do
    @moduledoc """
    What our own Group actor declares about its rules, so remote software can honour them.

    We already READ these on the way in: `postingRestrictedToMods` and `manuallyApprovesFollowers`/`openness` are what `Categories.create_remote/2` scaffolds a mirrored community's dimensions from. Emitting them is the other half, and it is not cosmetic — remote UIs key off them. A community that advertises `postingRestrictedToMods` gets its compose button hidden on Lemmy, Mbin, PieFed and NodeBB, so a moderators-only group that stays silent invites people to write posts it will never accept, and they find out only by being ignored. `manuallyApprovesFollowers` is what Mastodon reads to show a follow as pending rather than accepted.

    The mapping is from the group's own dimensions, so it cannot drift from the boundaries actually enforced: participation `moderators` is the only one that restricts posting to mods, and membership `on_request` is the only one that reviews joins.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Classify.Categories

    defp actor_data(group) do
      assert %{data: data} = Categories.format_actor(group)
      data
    end

    defp group_with(creator, dims) do
      group = fake_group!(creator)
      assert :ok = Bonfire.Classify.Boundaries.apply(group, creator, dims)
      {:ok, group} = Categories.get(id(group), skip_boundary_check: true)
      group
    end

    describe "postingRestrictedToMods" do
      test "is true for a group only moderators may post in" do
        creator = Bonfire.Me.Fake.fake_user!()

        group =
          group_with(creator, %{
            membership: "invite_only",
            visibility: "global",
            participation: "moderators",
            default_content_visibility: "public"
          })

        assert actor_data(group)["postingRestrictedToMods"] == true,
               "an announcement channel that does not say so gets people writing posts it will silently never accept"
      end

      # An archived group accepts nothing from anyone (`soft_delete/2` locks it), so the field that tells remote software "do not offer a compose button" has to say so. Read from the archive flag rather than from boundaries: a circle-level check cannot tell a locked group from one only its MEMBERS may post in, and marking the latter restricted would hide the compose button from people who can in fact post.
      test "is true for an archived group" do
        creator = Bonfire.Me.Fake.fake_user!()

        group =
          group_with(creator, %{
            membership: "open",
            visibility: "global",
            participation: "anyone",
            default_content_visibility: "public"
          })

        assert actor_data(group)["postingRestrictedToMods"] == false,
               "control: while open it takes posts from anyone, so the assertion below is about archiving rather than about the preset"

        assert {:ok, archived} = Bonfire.Classify.Categories.soft_delete(group, creator)

        assert actor_data(archived)["postingRestrictedToMods"] == true
      end

      test "is false when anyone may post" do
        creator = Bonfire.Me.Fake.fake_user!()

        group =
          group_with(creator, %{
            membership: "open",
            visibility: "global",
            participation: "anyone",
            default_content_visibility: "public"
          })

        assert actor_data(group)["postingRestrictedToMods"] == false,
               "stated either way rather than omitted, since an absent flag reads as unknown rather than as open"
      end
    end

    describe "manuallyApprovesFollowers" do
      test "is true for a group whose joins are reviewed" do
        creator = Bonfire.Me.Fake.fake_user!()

        group =
          group_with(creator, %{
            membership: "on_request",
            visibility: "global",
            participation: "anyone",
            default_content_visibility: "public"
          })

        assert actor_data(group)["manuallyApprovesFollowers"] == true,
               "this is what Mastodon reads to show a join as pending rather than accepted"
      end

      test "is false for a group anyone may join" do
        creator = Bonfire.Me.Fake.fake_user!()

        group =
          group_with(creator, %{
            membership: "open",
            visibility: "global",
            participation: "anyone",
            default_content_visibility: "public"
          })

        assert actor_data(group)["manuallyApprovesFollowers"] == false
      end
    end

    # `openness` is the more specific field, and the one that can say what AS2's boolean cannot: it describes JOINING, where `manuallyApprovesFollowers` describes FOLLOWING. Our own ingest reads it first for exactly that reason (`Categories.remote_dims/1`), so emitting it keeps us readable by our own rules.
    describe "openness" do
      test "says how the group is joined, for each membership rule" do
        creator = Bonfire.Me.Fake.fake_user!()

        for {membership, expected} <- [
              {"open", "open"},
              {"on_request", "moderated"},
              {"invite_only", "invite_only"}
            ] do
          group =
            group_with(creator, %{
              membership: membership,
              visibility: "global",
              participation: "anyone",
              default_content_visibility: "public"
            })

          assert actor_data(group)["openness"] == expected,
                 "membership #{membership} should be advertised as openness #{expected}"
        end
      end
    end

    # The invariant that matters, and the one most likely to rot: emitting and reading live in different extensions (`AdapterUtils.format_actor/2` and `Categories.remote_dims/1`) and can be edited independently, so this asserts they are inverse across EVERY combination rather than for one lucky case. Both sides are our own code, so this needs no network — a dance test would only add evidence that serialisation does not drop fields, which does not vary per permutation.
    #
    # Only the dimensions the declarations can express are swept: `visibility` is not advertised (a group we federate at all is one remote software can see), and `default_content_visibility` is a per-post default rather than a group rule.
    test "every membership × participation combination survives emit-then-read unchanged" do
      creator = Bonfire.Me.Fake.fake_user!()

      memberships = ["open", "on_request", "invite_only"]
      participations = ["anyone", "local:contributors", "group_members", "moderators"]

      for membership <- memberships, participation <- participations do
        group =
          group_with(creator, %{
            membership: membership,
            visibility: "global",
            participation: participation,
            default_content_visibility: "public"
          })

        data = actor_data(group)

        # what our own ingest would scaffold from those declarations, per `Adapter.maybe_create_remote_actor/1`
        read_back = %{
          openness: data["openness"],
          posting_restricted_to_mods: data["postingRestrictedToMods"] == true
        }

        expected_openness =
          case membership do
            "open" -> "open"
            "on_request" -> "moderated"
            "invite_only" -> "invite_only"
          end

        assert read_back.openness == expected_openness,
               "#{membership}/#{participation}: a group that reviews joins must not arrive elsewhere as one anybody can walk into"

        assert read_back.posting_restricted_to_mods == (participation == "moderators"),
               "#{membership}/#{participation}: whether only mods may post is the one participation fact remote software acts on, so it has to survive the round trip exactly"
      end
    end
  end
end
