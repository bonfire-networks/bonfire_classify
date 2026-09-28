if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.JoinRequestLifecycleTest do
    @moduledoc """
    What happens to a join request after it is made: withdrawn by the requester, declined (ignored) by a moderator, asked again, accepted.

    Every end has to leave the request no longer pending for whoever reads it next, and asking again has to make a request moderators can act on, rather than reviving, or hiding behind, the one that ended. Membership and following are separate rows, so ending a join request must not touch a follow or a pending follow request.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Me.Fake
    alias Bonfire.Classify.Categories
    alias Bonfire.Social.Requests
    alias Bonfire.Social.Graph.Follows

    setup do
      Process.put(:federating, false)

      creator = Fake.fake_user!()
      moderator = Fake.fake_user!()
      requester = Fake.fake_user!()

      # a Private club: non-members get no `:follow`, so pressing Join leaves a follow request beside the join request
      group =
        fake_group!(creator, %{
          membership: "on_request",
          visibility: "members:private",
          participation: "group_members",
          default_content_visibility: "members:private"
        })

      {:ok, _} = Categories.add_moderator(creator, group, id(moderator))

      {:ok, moderator: moderator, requester: requester, group: group}
    end

    defp join_verb, do: Bonfire.Boundaries.Verbs.get_id!(:join)

    defp join_request!(requester, group) do
      assert {:ok, request} =
               Requests.get(requester, join_verb(), group, skip_boundary_check: true),
             "control: expected a join request row"

      request
    end

    defp pending?(requester, group), do: Requests.requested?(requester, join_verb(), group)

    # a request's notification is an activity sharing the request's id
    defp activity_exists?(request_id),
      do: repo().exists?(from(a in Bonfire.Data.Social.Activity, where: a.id == ^uid(request_id)))

    defp notification_ids(user) do
      Bonfire.Social.FeedLoader.feed(:notifications, current_user: user)
      |> e(:edges, [])
      |> Enum.map(&(e(&1, :activity, :id, nil) || id(&1)))
    end

    describe "withdrawing" do
      test "ends the request: no row, no notification left for a moderator to accept", %{
        moderator: moderator,
        requester: requester,
        group: group
      } do
        {:ok, %{requested: true}} = Categories.join_and_follow_group(requester, group)
        request = join_request!(requester, group)
        assert activity_exists?(request.id), "control: the moderators were notified"

        assert {:ok, _} = Categories.cancel_join_request(requester, group)

        assert {:error, _} =
                 Requests.get(requester, join_verb(), group, skip_boundary_check: true),
               "a withdrawn request must not linger as a row the group page reads back as pending"

        refute activity_exists?(request.id),
               "a withdrawn request's notification must not stay for a moderator to act on"

        assert {:error, _} = Follows.accept(request.id, current_user: moderator)

        refute Categories.member?(requester, group),
               "accepting a withdrawn request must not make a member"
      end

      test "leaves the pending follow request that pressing Join also made, and its notification",
           %{requester: requester, group: group} do
        {:ok, %{requested: true}} = Categories.join_and_follow_group(requester, group)

        assert {:ok, follow_request} =
                 Requests.get(requester, Bonfire.Data.Social.Follow, group,
                   skip_boundary_check: true
                 ),
               "control: this group grants non-members no :follow, so the follow half waits as its own request"

        {:ok, _} = Categories.cancel_join_request(requester, group)

        assert {:ok, %{id: same_id}} =
                 Requests.get(requester, Bonfire.Data.Social.Follow, group,
                   skip_boundary_check: true
                 )

        assert same_id == follow_request.id

        assert activity_exists?(follow_request.id),
               "join and follow requests share the :request verb, so cleaning up by verb would also remove the follow request's notification and strand it"
      end

      test "keeps an existing follow" do
        creator = Fake.fake_user!()
        requester = Fake.fake_user!()
        # a group whose visibility grants non-members a plain follow
        group = fake_group!(creator, %{membership: "on_request", visibility: "nonfederated"})

        {:ok, %{following: true}} = Categories.follow_group(requester, group)
        {:ok, %{requested: true}} = Categories.join_group(requester, group)

        {:ok, _} = Categories.cancel_join_request(requester, group)

        refute pending?(requester, group)
        assert Follows.following?(requester, group), "withdrawing a join is not unsubscribing"
      end

      test "asking again after withdrawing makes a new pending request", %{
        requester: requester,
        group: group
      } do
        {:ok, _} = Categories.join_group(requester, group)
        old = join_request!(requester, group)
        {:ok, _} = Categories.cancel_join_request(requester, group)

        assert {:ok, %{requested: true}} = Categories.join_group(requester, group)

        new = join_request!(requester, group)
        assert pending?(requester, group)
        assert new.id != old.id
        assert activity_exists?(new.id)
      end
    end

    describe "declining (ignoring)" do
      test "sends the requester nothing", %{
        moderator: moderator,
        requester: requester,
        group: group
      } do
        {:ok, _} = Categories.join_and_follow_group(requester, group)
        request = join_request!(requester, group)
        before = notification_ids(requester)

        assert {:ok, _} = Follows.ignore(request.id, current_user: moderator)

        assert notification_ids(requester) == before,
               "a decline must be silent for the requester"

        refute pending?(requester, group)
        refute Categories.member?(requester, group)
      end

      test "asking again makes a fresh request with its own notification, which a moderator can accept",
           %{moderator: moderator, requester: requester, group: group} do
        {:ok, _} = Categories.join_and_follow_group(requester, group)
        declined = join_request!(requester, group)
        {:ok, _} = Follows.ignore(declined.id, current_user: moderator)

        assert {:ok, %{requested: true}} = Categories.join_and_follow_group(requester, group)

        assert pending?(requester, group),
               "asking again after a decline must leave a pending request, not the ignored one"

        new = join_request!(requester, group)
        assert new.id != declined.id, "a new attempt gets its own identity"
        refute activity_exists?(declined.id), "the declined attempt's notification is gone"

        assert new.id in notification_ids(moderator),
               "the new request must reach the moderators' notifications"

        assert {:ok, _} = Follows.accept(new.id, current_user: moderator)
        assert Categories.member?(requester, group)
        assert Follows.following?(requester, group)
      end

      test "an Accept left on the declined attempt cannot settle the new one", %{
        moderator: moderator,
        requester: requester,
        group: group
      } do
        {:ok, _} = Categories.join_group(requester, group)
        declined = join_request!(requester, group)
        {:ok, _} = Follows.ignore(declined.id, current_user: moderator)
        {:ok, _} = Categories.join_group(requester, group)

        assert {:error, _} = Follows.accept(declined.id, current_user: moderator)

        refute Categories.member?(requester, group)
        assert pending?(requester, group), "the new request is still waiting for its own decision"
      end
    end

    # Accepting already checks `:mediate` (see `groups_test.exs`); declining is the other decision and must be gated the same way. Each refusal is paired with the same act by a moderator, since "refused" and "never worked" look identical from one assertion.
    describe "decision authority" do
      setup do
        creator = Fake.fake_user!()
        moderator = Fake.fake_user!()
        requester = Fake.fake_user!()
        outsider = Fake.fake_user!()
        member = Fake.fake_user!()

        # readable by any local, so an outsider passes the default `:see`/`:read` check and only the decision gate can refuse them
        group = fake_group!(creator, %{membership: "on_request", visibility: "nonfederated"})

        {:ok, _} = Categories.add_moderator(creator, group, id(moderator))
        {:ok, _} = Categories.add_member(creator, group, id(member))
        {:ok, _} = Categories.join_group(requester, group)

        {:ok,
         moderator: moderator,
         requester: requester,
         outsider: outsider,
         member: member,
         group: group,
         request: join_request!(requester, group)}
      end

      for actor <- [:outsider, :member] do
        test "a #{actor} cannot decline a join request",
             %{requester: requester, group: group} =
               ctx do
          assert {:error, _} = Follows.ignore(ctx.request.id, current_user: ctx[unquote(actor)])

          assert pending?(requester, group), "a refused decline must leave the request pending"

          assert {:ok, _} = Follows.ignore(ctx.request.id, current_user: ctx.moderator),
                 "control: a moderator can decline it"

          refute pending?(requester, group)
        end

        test "a #{actor} cannot accept a join request",
             %{requester: requester, group: group} =
               ctx do
          assert {:error, _} = Follows.accept(ctx.request.id, current_user: ctx[unquote(actor)])

          refute Categories.member?(requester, group)
          assert pending?(requester, group), "a refused accept must not consume the request"
        end
      end
    end
  end
end
