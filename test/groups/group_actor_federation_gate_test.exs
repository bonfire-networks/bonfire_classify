if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupActorFederationGateTest do
    @moduledoc """
    Groups with nonfederated visibility must not be dereferenceable as ActivityPub actors, regardless of what web guests may see.
    The control assertion (a regular user's actor IS served) proves federation is otherwise enabled in this test env, so a refusal for a group is meaningful.
    """
    use Bonfire.Classify.ConnCase, async: false
    use Bonfire.Common.Utils

    # follows the 301 from the username URL to the canonical /pub/<type>/<ULID> URL
    defp fetch_actor_conn(path) do
      conn = build_conn() |> get(path)

      case conn.status do
        301 -> build_conn() |> get(redirected_to(conn, 301))
        _ -> conn
      end
    end

    defp actor_status(character) do
      fetch_actor_conn("/pub/actors/#{e(character, :character, :username, nil)}").status
    end

    test "control: a regular user's actor is served over AP" do
      assert actor_status(fake_user!()) == 200
    end

    test "group with the public_local_community preset dims is not served over AP" do
      creator = fake_user!()

      # explicit dims of the `public_local_community` preset (the UI default):
      # `nonfederated:discoverable` grants guests :see but not :read
      group =
        fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors"
        })

      status = actor_status(group)

      assert status in [401, 403, 404],
             "nonfederated group's actor was served over AP (status #{status}), there's a federation leak"
    end

    test "group with guest-readable plain nonfederated visibility is still not served over AP" do
      creator = fake_user!()

      # plain `nonfederated` visibility grants web guests :read but denies the activity_pub
      # circle — visible on the open web, NOT federated. The AP actor endpoint must refuse it.
      group =
        fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated",
          participation: "anyone"
        })

      status = actor_status(group)

      assert status in [401, 403, 404],
             "guest-readable nonfederated group's actor was served over AP (status #{status}), there's a federation leak"
    end

    test "group with global visibility IS served over AP" do
      creator = fake_user!()

      # `global` visibility grants the activity_pub circle read, which is the one federated visibility.
      # Guards against the gate over-blocking once it keys on the activity_pub circle.
      group =
        fake_group!(creator, %{
          membership: "local:members",
          visibility: "global",
          participation: "anyone"
        })

      assert actor_status(group) == 200
    end

    # The gate has to open again, not only shut: a group that starts local and later decides to federate is an ordinary thing for an admin to want, and the test above only proves the gate opens for a group BORN federated. `sync_activity_pub_visibility/3` writes its deny onto the group's OWN custom ACL, which is not one of the dimension ACLs `apply/4` swaps out, so the switch has to take it back explicitly.
    test "a group switched from nonfederated to global is served over AP" do
      creator = fake_user!()

      group =
        fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors"
        })

      assert actor_status(group) in [401, 403, 404],
             "control: it starts out refused, so serving it below means the switch did something"

      assert :ok =
               Bonfire.Classify.Boundaries.replace(group, creator, %{
                 membership: "open",
                 visibility: "global",
                 participation: "anyone",
                 default_content_visibility: "public"
               })

      assert actor_status(group) == 200,
             "a group whose admin has just made it federated must federate, otherwise the only way to have a federated group is to never have had a local one"
    end

    test "actor updates are not pushed for a nonfederated group" do
      creator = fake_user!()

      group =
        fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors"
        })

      assert :ignore = Bonfire.Federate.ActivityPub.Outgoing.push_actor_update(group)
    end

    test "nonfederated group's actor is not served via its canonical ULID URL either" do
      creator = fake_user!()

      group =
        fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors"
        })

      # the by-id route resolves via `get_character_by_id`/`Actor.get_cached(pointer:)`, a different lookup path than the username one, so gate it explicitly
      status = fetch_actor_conn("/pub/group/#{uid(group)}").status

      assert status in [401, 403, 404],
             "nonfederated group's actor was served via ULID URL (status #{status}), there's a federation leak"
    end

    # A browser following a group's canonical ULID URL (from a remote profile, a link someone pasted, a search result) is a person, not a server, so the AP gate above does not apply to it: it should land on the group page, which then shows whatever that page shows the viewer. For a private group that is the hero and a sign-in prompt, not an error.
    describe "a browser opening a group's actor URL" do
      defp open_in_browser(path),
        do: build_conn() |> put_req_header("accept", "text/html") |> get(path)

      test "is redirected to the group page for a federating group" do
        group = fake_group!(fake_user!(), %{visibility: "global"})

        conn = open_in_browser("/pub/group/#{uid(group)}")

        assert redirected_to(conn, 302) == Bonfire.Common.URIs.path(group),
               "control: the HTML branch works where the AP lookup succeeds, so a failure below is the private case specifically"
      end

      test "is redirected to the group page for a private group, too" do
        group =
          fake_group!(fake_user!(), %{
            membership: "invite_only",
            visibility: "members:private",
            participation: "group_members"
          })

        conn = open_in_browser("/pub/group/#{uid(group)}")

        assert conn.status == 302,
               "a private group is not served over AP, but a person opening its link should still reach its page, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 120)}"

        assert redirected_to(conn, 302) == Bonfire.Common.URIs.path(group)
      end

      # the older username form reaches the same redirect, and a username alone reads as a person, so it has to be resolved to the character to land on a GROUP page
      test "reaches the group page from the username actor URL as well" do
        group =
          fake_group!(fake_user!(), %{
            membership: "invite_only",
            visibility: "members:private",
            participation: "group_members"
          })

        conn = open_in_browser("/pub/actors/#{group.character.username}")

        assert redirected_to(conn, 302) == Bonfire.Common.URIs.path(group)
      end

      test "a server fetching the same private group's URL is still refused" do
        group =
          fake_group!(fake_user!(), %{
            membership: "invite_only",
            visibility: "members:private",
            participation: "group_members"
          })

        status = fetch_actor_conn("/pub/group/#{uid(group)}").status

        assert status in [401, 403, 404],
               "redirecting browsers must not open the AP door: a private group's actor was served (status #{status})"
      end
    end

    test "group with backend default dims (local:unlisted) is not served over AP" do
      creator = fake_user!()

      # no dims passed: `resolve_dims` falls back to membership `on_request` +
      # visibility `local:unlisted` (guests get nothing at all)
      group = fake_group!(creator)

      status = actor_status(group)

      assert status in [401, 403, 404],
             "local-only group's actor was served over AP (status #{status}), there's a federation leak"
    end
  end
end
