if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupDimensionNarrowingTest do
    @moduledoc """
    Changing a group's dimensions has to work in both directions.

    Widening is the easy case, since granting a more permissive role adds verbs. Narrowing is where it gets interesting: `Bonfire.Boundaries.Grants.grant_role/4` grants a role's verbs and only writes negatives for explicit "cannot" roles, so a narrower role does not by itself take away what a previous one granted. `Bonfire.Classify.Boundaries.apply/4` removes the previous preset's dimension ACLs, but `grant_member_access/4` writes to the group's own custom ACL, which is not part of that set.

    This is the path the settings UI uses (`set_group_boundaries` calls the same `apply/4`), and the path a mirrored remote community uses when it starts restricting posting, so it matters twice.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Me.Fake
    alias Bonfire.Boundaries
    alias Bonfire.Boundaries.Presets

    setup do
      Process.put(:federating, false)
      :ok
    end

    defp participation_of(group) do
      {:ok, reloaded} = Bonfire.Classify.Categories.get(id(group), skip_boundary_check: true)
      Presets.group_dimension_slugs(reloaded)[:participation]
    end

    # deliberately WITHOUT `previous_preset`: `apply/4` derives it from the group's current state, so
    # a caller that does not know (federation, a script) gets the same result as one that does
    defp apply_dims(group, creator, participation) do
      Bonfire.Classify.Boundaries.replace(group, creator, %{
        membership: "open",
        visibility: "global",
        participation: participation,
        default_content_visibility: "public"
      })
    end

    test "narrowing participation from members to moderators takes effect" do
      creator = Fake.fake_user!()
      group = fake_group!(creator)

      assert :ok = apply_dims(group, creator, "group_members")
      assert participation_of(group) == "group_members"

      assert :ok = apply_dims(group, creator, "moderators")

      assert participation_of(group) == "moderators",
             "a group that restricts posting to moderators must stop reporting that members can post"
    end

    # `detect_circle_participation/1` checks the members circle before the moderators one, so the
    # group could enforce moderators-only while still REPORTING "group_members". That distinction
    # decides whether the failures above are a display bug or a permissions one.
    test "a plain member cannot post in a moderators-only group, whatever the dimension reports" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()
      group = fake_group!(creator)

      assert {:ok, _} = Bonfire.Classify.Categories.add_member(creator, group, id(member))
      assert :ok = apply_dims(group, creator, "moderators")

      refute Boundaries.can?(member, :create, group),
             "posting is restricted to moderators, so an ordinary member must not be able to post"
    end

    test "a moderator can post in a moderators-only group" do
      creator = Fake.fake_user!()
      mod = Fake.fake_user!()
      group = fake_group!(creator)

      assert {:ok, _} = Bonfire.Classify.Categories.add_moderator(creator, group, id(mod))
      assert :ok = apply_dims(group, creator, "moderators")

      assert Boundaries.can?(mod, :create, group),
             "the whole point of moderators-only is that moderators can still post"
    end

    # Changing participation re-grants the members circle's role. It must not take away grants that
    # have nothing to do with participation: an admin who deliberately gave the members circle an
    # extra capability on the group should still have it after someone edits the boundary.
    test "changing participation leaves unrelated grants on the members circle alone" do
      creator = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, circle} = Bonfire.Classify.Categories.members_circle(group)

      Bonfire.Boundaries.Controlleds.grant_role(circle, group, :moderate, current_user: creator)

      assert :ok = apply_dims(group, creator, "moderators")

      assert Bonfire.Boundaries.Controlleds.subject_has_verb_on_object?(group, circle, :mediate),
             "a bespoke grant is not part of the participation role, so applying a preset must not remove it"
    end

    test "widening participation from moderators to members takes effect" do
      creator = Fake.fake_user!()
      group = fake_group!(creator)

      assert :ok = apply_dims(group, creator, "moderators")
      assert participation_of(group) == "moderators"

      assert :ok = apply_dims(group, creator, "group_members")

      assert participation_of(group) == "group_members"
    end

    # Membership narrows the same way participation does, and it is the dimension the `joins_need_approval` toggle writes to: ticking it moves a group from `open` to `on_request`. The reported slug and the `:join` verb are asserted separately, since a group can enforce one while reporting the other.
    defp membership_of(group) do
      {:ok, reloaded} = Bonfire.Classify.Categories.get(id(group), skip_boundary_check: true)
      Presets.group_dimension_slugs(reloaded)[:membership]
    end

    defp apply_membership(group, creator, membership) do
      Bonfire.Classify.Boundaries.replace(group, creator, %{
        membership: membership,
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })
    end

    test "requiring approval narrows membership from open to on_request and revokes :join" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()
      group = fake_group!(creator)

      assert :ok = apply_membership(group, creator, "open")
      assert membership_of(group) == "open"

      assert Boundaries.can?(stranger, :join, group),
             "an open group is the control: without it, a revoked :join is indistinguishable from one never granted"

      assert :ok = apply_membership(group, creator, "on_request")

      assert membership_of(group) == "on_request"

      refute Boundaries.can?(stranger, :join, group),
             "a group that reviews joins must stop granting :join outright"

      assert Boundaries.can?(stranger, :request, group),
             "reviewing joins means asking is still possible, which is the whole difference from invite_only"
    end

    test "opening membership from on_request back to open grants :join again" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()
      group = fake_group!(creator)

      assert :ok = apply_membership(group, creator, "on_request")
      refute Boundaries.can?(stranger, :join, group)

      assert :ok = apply_membership(group, creator, "open")

      assert membership_of(group) == "open"
      assert Boundaries.can?(stranger, :join, group)
    end

    # A group's three dimension slugs are applied as one boundary list, and a visibility that is also a POST preset name (`unlisted`, `local`) was once resolved as that whole preset, silently dropping the membership and participation slugs beside it. Seen as an open unlisted group declaring `openness: "invite_only"` to a peer in the unlisted group dance test. `global`, which no post preset is named, is the control
    for {visibility, membership, participation} <- [
          {"global", "open", "anyone"},
          {"unlisted", "open", "anyone"},
          {"local", "on_request", "local:contributors"}
        ] do
      test "a #{membership} #{visibility} group keeps all three dimensions" do
        creator = Fake.fake_user!()
        group = fake_group!(creator)

        expected = %{
          membership: unquote(membership),
          visibility: unquote(visibility),
          participation: unquote(participation)
        }

        assert :ok =
                 Bonfire.Classify.Boundaries.replace(
                   group,
                   creator,
                   Map.put(expected, :default_content_visibility, "public")
                 )

        {:ok, reloaded} = Bonfire.Classify.Categories.get(id(group), skip_boundary_check: true)

        assert Map.take(Presets.group_dimension_slugs(reloaded), [
                 :membership,
                 :visibility,
                 :participation
               ]) == expected
      end
    end

    # unlisted means readable but not listed, so open membership mustn't hand out `see` on its own: that's the visibility dimension's job. `global` is the control, where visibility grants `see` itself
    for {visibility, see?} <- [{"global", true}, {"unlisted", false}] do
      test "an open #{visibility} group #{if see?, do: "is", else: "isn't"} seen by a stranger, who can read it either way" do
        creator = Fake.fake_user!()
        stranger = Fake.fake_user!()
        group = fake_group!(creator)

        assert :ok =
                 Bonfire.Classify.Boundaries.replace(group, creator, %{
                   membership: "open",
                   visibility: unquote(visibility),
                   participation: "anyone",
                   default_content_visibility: "public"
                 })

        assert Boundaries.can?(stranger, :read, group)
        assert Boundaries.can?(stranger, :see, group) == unquote(see?)
      end
    end

    # creation takes its dimensions through `init_boundaries/4` rather than `replace/4`, which the tests above go through, so it gets its own round trip
    for {visibility, see?} <- [{"global", true}, {"unlisted", false}] do
      test "an open #{visibility} group created with its dimensions keeps them, and #{if see?, do: "is", else: "isn't"} seen by a stranger" do
        creator = Fake.fake_user!()
        stranger = Fake.fake_user!()

        group =
          fake_group!(creator, %{membership: "open", visibility: unquote(visibility)})

        {:ok, reloaded} = Bonfire.Classify.Categories.get(id(group), skip_boundary_check: true)

        assert Map.take(Presets.group_dimension_slugs(reloaded), [:membership, :visibility]) ==
                 %{membership: "open", visibility: unquote(visibility)}

        assert Boundaries.can?(stranger, :read, group)
        assert Boundaries.can?(stranger, :see, group) == unquote(see?)
      end
    end

    # a slug no dimension declares grants nothing, so a group given one would exist without that boundary at all, seen by nobody but its members. Refused before anything is written, since the boundaries are set up after the group is inserted
    test "creating a group with an undeclared visibility is refused, and creates nothing" do
      creator = Fake.fake_user!()
      declared_name = "declared #{Needle.ULID.generate()}"
      undeclared_name = "undeclared #{Needle.ULID.generate()}"

      named? = fn name ->
        repo().exists?(from(p in Bonfire.Data.Social.Profile, where: p.name == ^name))
      end

      assert {:ok, _} =
               Bonfire.Classify.Categories.create(creator, %{
                 type: :group,
                 name: declared_name,
                 membership: "open",
                 visibility: "global"
               })

      assert named?.(declared_name), "control: a created group is found by its name"

      assert {:error, _} =
               Bonfire.Classify.Categories.create(creator, %{
                 type: :group,
                 name: undeclared_name,
                 membership: "open",
                 visibility: "global:undeclared"
               })

      refute named?.(undeclared_name), "the refused group was written anyway"
    end

    # `apply_changes/4` is what the settings UI and the API call with whoever is signed in, so it's where managing the group is checked: its creator or a moderator, as `Classify.ensure_update_allowed/2` decides for the rest of the group's settings
    test "a group's creator and its moderators may change its dimensions, and a stranger may not" do
      creator = Fake.fake_user!()
      moderator = Fake.fake_user!()
      stranger = Fake.fake_user!()
      group = fake_group!(creator, %{membership: "open", visibility: "global"})
      {:ok, _} = Bonfire.Classify.Categories.add_moderator(creator, group, id(moderator))

      dims_of = fn ->
        {:ok, reloaded} = Bonfire.Classify.Categories.get(id(group), skip_boundary_check: true)
        Map.take(Presets.group_dimension_slugs(reloaded), [:membership, :visibility])
      end

      assert {:error, _} =
               Bonfire.Classify.Boundaries.apply_changes(group, stranger, %{
                 dims: %{membership: "invite_only"}
               })

      assert dims_of.() == %{membership: "open", visibility: "global"},
             "a stranger changed the group's boundaries"

      assert :ok =
               Bonfire.Classify.Boundaries.apply_changes(group, moderator, %{
                 dims: %{membership: "on_request"}
               })

      assert dims_of.().membership == "on_request"

      assert :ok =
               Bonfire.Classify.Boundaries.apply_changes(group, creator, %{
                 dims: %{membership: "open"}
               })

      assert dims_of.().membership == "open"
    end

    test "replacing a group's dimensions with an undeclared visibility is refused, and changes nothing" do
      creator = Fake.fake_user!()
      group = fake_group!(creator, %{membership: "open", visibility: "global"})

      assert {:error, _} =
               Bonfire.Classify.Boundaries.replace(group, creator, %{
                 membership: "open",
                 visibility: "global:undeclared"
               })

      {:ok, reloaded} = Bonfire.Classify.Categories.get(id(group), skip_boundary_check: true)

      assert Map.take(Presets.group_dimension_slugs(reloaded), [:membership, :visibility]) ==
               %{membership: "open", visibility: "global"}
    end

    # who may post says nothing about who may read: `preview` shows the group to everyone and its content to members only, so a non-member who may post still can't read. Participation used to grant the cumulative `contribute` role, which carried `read` (and `see`) with it
    test "a non-member of a preview group anyone may post in sees it but can't read it" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()
      group = fake_group!(creator)

      assert :ok =
               Bonfire.Classify.Boundaries.replace(group, creator, %{
                 membership: "open",
                 visibility: "preview",
                 participation: "anyone",
                 default_content_visibility: "public"
               })

      assert Boundaries.can?(stranger, :see, group)
      refute Boundaries.can?(stranger, :read, group)
    end

    # Posting without reading is not currently offered: a visibility that shows the group but keeps its content for members (`preview`, the `:preview_discover` role) disables every participation option that lets non-members post, the way the reach rule disables options wider than who can reach the group. The group page agrees, since a visitor without `read` gets the preview, which has no composer. `unlisted`, readable by anyone, is the control
    for {visibility, offers_nonmember_posting?} <- [
          {"preview", false},
          {"local:preview", false},
          {"nonfederated:preview", false},
          {"unlisted", true}
        ] do
      test "a #{visibility} group #{if offers_nonmember_posting?, do: "offers", else: "doesn't offer"} non-member posting" do
        disabled =
          Bonfire.Classify.Boundaries.disabled_options_by_reach(
            :participation,
            unquote(visibility)
          )

        nonmember_options =
          Enum.filter(
            Presets.dimension_slug_order(:participation),
            &(&1 == "anyone" or String.ends_with?(&1, ":contributors"))
          )

        assert nonmember_options != [], "control: there are non-member options to disable"

        if unquote(offers_nonmember_posting?) do
          assert "anyone" not in disabled
        else
          assert Enum.all?(nonmember_options, &(&1 in disabled)),
                 "who may post must not be wider than who may read: #{inspect(disabled)}"
        end
      end
    end
  end
end
