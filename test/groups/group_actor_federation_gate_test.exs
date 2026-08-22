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
          visibility: "nonfederated:discoverable",
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

    test "actor updates are not pushed for a nonfederated group" do
      creator = fake_user!()

      group =
        fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:discoverable",
          participation: "local:contributors"
        })

      assert :ignore = Bonfire.Federate.ActivityPub.Outgoing.push_actor_update(group)
    end

    test "nonfederated group's actor is not served via its canonical ULID URL either" do
      creator = fake_user!()

      group =
        fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:discoverable",
          participation: "local:contributors"
        })

      # the by-id route resolves via `get_character_by_id`/`Actor.get_cached(pointer:)`, a different lookup path than the username one, so gate it explicitly
      status = fetch_actor_conn("/pub/group/#{uid(group)}").status

      assert status in [401, 403, 404],
             "nonfederated group's actor was served via ULID URL (status #{status}), there's a federation leak"
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
