if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupDimensionNarrowingTest do
    @moduledoc """
    Changing a group's dimensions has to work in both directions.

    Widening is the easy case, since granting a more permissive role adds verbs. Narrowing is where it gets interesting: `Bonfire.Boundaries.Grants.grant_role/4` grants a role's verbs and only writes negatives for explicit "cannot" roles, so a narrower role does not by itself take away what a previous one granted. `Bonfire.Classify.Boundaries.apply/4` removes the previous preset's
    dimension ACLs, but `grant_member_access/4` writes to the group's own custom ACL, which is not
    part of that set.

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
      Bonfire.Classify.Boundaries.apply(group, creator, %{
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
      Bonfire.Classify.Boundaries.apply(group, creator, %{
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
  end
end
