if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.DataMigrations.GroupAclSignaturesTest do
    @moduledoc """
    Groups created before the membership signatures grew still report the membership they were created with, once backfilled.

    A group's membership is STORED as the set of ACLs applied to it, and the slug is read back by matching those ACLs (`Presets.membership_slug/1`, `MapSet.subset?`). So a signature gaining an ACL is a data change, not just a config one: `open` went from `[:everyone_may_see_read]` to that plus `:everyone_may_join` and `:everyone_may_request`, and a group carrying only the old one stops matching and falls back to `invite_only`. The backfill adds what the signature grew.

    It also re-points the six ACLs that were versioned when `:request` left the read bundles and `:join` left `verbs_partake`. Those kept their names and took new ids, so a group still pointing at a deprecated id carries the old, wider grants.
    """
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils

    alias Bonfire.Boundaries.Acls
    alias Bonfire.Boundaries.Controlleds
    alias Bonfire.Boundaries.Presets
    alias Bonfire.Classify.Boundaries.GroupAclSignaturesDataMigration
    alias Bonfire.Classify.Simulate
    alias Bonfire.Common.Repo
    alias Bonfire.Me.Fake

    setup do
      # nothing here federates; applying boundaries otherwise spawns federation tasks with no DB ownership in tests
      Process.put(:federating, false)
      :ok
    end

    defp run_backfill do
      GroupAclSignaturesDataMigration.base_query()
      |> Repo.all()
      |> GroupAclSignaturesDataMigration.migrate()
    end

    # Writes the grants a legacy instance already holds for `no_follow`, which a FRESH one never creates: a deprecated ACL is skipped by both `config_current_acls/0` and `grants_fixtures/0`, so its row and grants only exist where they predate the deprecation. Attaching the ACL without them denies nothing, and the legacy state this test is about cannot be reproduced.
    defp seed_deprecated_no_follow_grants do
      acl_id = Acls.get_id!(:no_follow)

      # the ACL ROW as well as the grants: `config_current_acls/0` rejects deprecated entries, so a fresh instance has neither, and a grant against a missing acl_id has nothing to hang on
      Repo.insert_all(
        Bonfire.Data.AccessControl.Acl,
        [%{id: acl_id}],
        on_conflict: :nothing
      )

      for circle <- [:local, :activity_pub] do
        assert {:ok, _} =
                 Bonfire.Boundaries.Grants.grant(
                   Bonfire.Boundaries.Circles.get_id!(circle),
                   acl_id,
                   :follow,
                   false,
                   skip_boundary_check: true
                 )
      end
    end

    # Rewinds a group to the shape it would have had before this change: the membership ACLs the `open` signature grew are removed, leaving only `everyone_may_see_read`. That one is added back too, since a group created now never gets it (`open` stopped granting `see`)
    defp rewind_to_old_open_signature(group) do
      Controlleds.remove_acls(group, [:everyone_may_join, :everyone_may_request])
      Controlleds.add_acls(group, :everyone_may_see_read)
      group
    end

    # A deprecated ACL exists so instances that already hold rows against it keep working, and the backfill is the only thing that moves them off. One left out strands every group still pointing at it, indefinitely and silently, and deprecating an ACL without handling it is a single-line mistake with no other symptom.
    #
    # There are two ways to handle one, so both count: an ACL that was VERSIONED is re-pointed to the live id that replaced it, and one that was RETIRED is taken off with nothing put in its place.
    test "every deprecated ACL is either re-pointed or retired by the backfill" do
      mapped =
        GroupAclSignaturesDataMigration.versioned()
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.union(
          GroupAclSignaturesDataMigration.retired()
          |> Map.values()
          |> List.flatten()
          |> MapSet.new()
        )

      deprecated =
        Bonfire.Boundaries.Acls.acls()
        |> Enum.filter(fn {_slug, acl} -> acl[:deprecated] end)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()

      assert MapSet.size(deprecated) > 0,
             "the control: there are deprecated ACLs, so the assertion below is not vacuous"

      unmapped = MapSet.difference(deprecated, mapped)

      assert MapSet.equal?(unmapped, MapSet.new()),
             "deprecated with nothing to re-point them to and nothing retiring them, so groups stay on the legacy grants forever: #{inspect(MapSet.to_list(unmapped))}"
    end

    test "a group created with the old open signature reads as open again after the backfill" do
      creator = Fake.fake_user!()
      group = Simulate.fake_group!(creator, %{membership: "open"})

      assert Presets.membership_slug(group) == "open",
             "the control: the group really is open before anything is rewound, so the failure below is about the missing ACLs rather than the fixture"

      rewind_to_old_open_signature(group)

      assert Presets.membership_slug(group) == "invite_only",
             "an open group carrying only the old signature no longer matches it, which is what makes the backfill necessary rather than cosmetic"

      run_backfill()

      assert Presets.membership_slug(group) == "open"
    end

    test "the backfill re-points a group from a deprecated ACL to its live replacement" do
      creator = Fake.fake_user!()
      group = Simulate.fake_group!(creator, %{membership: "open", visibility: "nonfederated"})

      live_id = Acls.get_id!(:guests_may_see_read)
      deprecated_id = Acls.get_id!(:guests_may_see_read_request)

      # A fresh install never creates deprecated ACLs (`Scaffold.Instance` skips them), so the legacy row has to be inserted here to simulate the UPGRADED instance this backfill exists for — otherwise there is nothing to attach and the test would pass vacuously.
      Repo.insert_all_or_ignore(Bonfire.Data.AccessControl.Acl, [%{id: deprecated_id}])

      # put the group back on the deprecated ACL, as one created before the split would be
      Controlleds.remove_acls(group, [:guests_may_see_read])
      Controlleds.add_acls(group, :guests_may_see_read_request)

      assert deprecated_id in acl_ids_on(group)

      run_backfill()

      acl_ids = acl_ids_on(group)

      assert live_id in acl_ids,
             "the group has to end up on the ACL whose grants no longer include `:request`"

      refute deprecated_id in acl_ids,
             "leaving the deprecated one attached would keep granting what the versioning removed"
    end

    # An `on_request` group used to apply `no_follow` alongside `everyone_may_request`, so reviewing
    # who could JOIN also denied everyone the group's FEED. Nothing prunes a `Controlled` row, so a
    # group created before that changed keeps the denial until this backfill takes it off.
    test "the backfill stops an on_request group from denying follows" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()

      group =
        Simulate.fake_group!(creator, %{membership: "on_request", visibility: "nonfederated"})

      assert Bonfire.Boundaries.can?(stranger, :follow, group),
             "the control: a group that reviews entry still grants `:follow`, so the refusal below is the legacy ACL rather than the fixture"

      # put the group back where one created under the old signature would be
      seed_deprecated_no_follow_grants()
      Controlleds.add_acls(group, :no_follow)

      refute Bonfire.Boundaries.can?(stranger, :follow, group),
             "a negative grant wins, which is what leaves these groups unfollowable"

      run_backfill()

      refute Acls.get_id!(:no_follow) in acl_ids_on(group)

      assert Bonfire.Boundaries.can?(stranger, :follow, group),
             "reviewing who may join says nothing about who may subscribe to the feed"
    end

    # `open` used to grant `everyone_may_see_read` itself, so an open group was listed whatever its visibility said. Seeing a group is the visibility dimension's answer, so the backfill takes the grant off, the same way it took `no_follow` off `on_request`
    test "the backfill stops an open group granting see on its own" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()

      group =
        Simulate.fake_group!(creator, %{
          membership: "open",
          visibility: "unlisted",
          participation: "anyone"
        })

      # put the group back where one created under the old signature would be
      Controlleds.add_acls(group, :everyone_may_see_read)

      assert Bonfire.Boundaries.can?(stranger, :see, group),
             "the control: the old grant does list an unlisted group, so the refusal below is the backfill's doing"

      run_backfill()

      refute Acls.get_id!(:everyone_may_see_read) in acl_ids_on(group)
      refute Bonfire.Boundaries.can?(stranger, :see, group)

      assert Bonfire.Boundaries.can?(stranger, :read, group),
             "unlisted is about listing, not access"

      assert Presets.membership_slug(group) == "open"
    end

    test "the backfill leaves an already-current group untouched" do
      creator = Fake.fake_user!()
      group = Simulate.fake_group!(creator, %{membership: "open"})

      before = acl_ids_on(group) |> Enum.sort()

      run_backfill()

      assert acl_ids_on(group) |> Enum.sort() == before,
             "re-running has to be a no-op, since the backfill runs on every deploy"
    end

    # A group scaffolded by `Scaffold.Groups.DataMigration` before it granted members access never got the members circle's per-group role (`grant_member_access`), which is the only thing that lets a member read a group whose visibility is `nonfederated:preview` (the global participation ACLs no longer grant read). Rewound here by taking that role off a normally created group, since the grant is exactly what was missing.
    test "the scaffold backfill lets the members and moderators of an older preview-only group read it" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()
      moderator = Fake.fake_user!()
      stranger = Fake.fake_user!()

      dims = %{
        membership: "local:members",
        visibility: "nonfederated:preview",
        participation: "local:contributors"
      }

      # the control: a normally created group, joined through the real path, reads for its member
      normal = Simulate.fake_group!(creator, dims)
      assert {:ok, _} = Bonfire.Classify.Categories.join_group(member, normal)

      assert {:ok, _} = Bonfire.Classify.Categories.get(normal.id, current_user: member),
             "the control: a member of a group created now reads it, so the failure below is the older group's missing grant"

      group = Simulate.fake_group!(creator, dims)
      assert {:ok, _} = Bonfire.Classify.Categories.join_group(member, group)
      assert {:ok, _} = Bonfire.Classify.Categories.add_moderator(creator, group, moderator)

      {:ok, members_circle} = Bonfire.Boundaries.Scaffold.Groups.members_circle(group)

      Bonfire.Boundaries.Controlleds.remove_role(members_circle, group, :contribute,
        current_user: creator
      )

      Bonfire.Boundaries.Scaffold.Instance.upsert_verbs_acls_and_grants()

      Bonfire.Boundaries.Scaffold.Groups.DataMigration.migrate([%{id: group.id}])

      member_read = Bonfire.Classify.Categories.get(group.id, current_user: member)
      moderator_read = Bonfire.Classify.Categories.get(group.id, current_user: moderator)

      assert match?({:ok, _}, member_read) and match?({:ok, _}, moderator_read),
             "a member and a moderator read their group once the scaffold backfill has run, got member #{inspect(elem(member_read, 0))}, moderator #{inspect(elem(moderator_read, 0))}"

      assert {:error, _} = Bonfire.Classify.Categories.get(group.id, current_user: stranger),
             "a non-member still only previews it"
    end

    # The scaffold backfill is already recorded as run on every instance that has it, so editing it reaches nobody. A group it scaffolded earlier is reached by a backfill of its own, over every group.
    test "the member access backfill lets the members of an older group read it, and is safe to re-run" do
      creator = Fake.fake_user!()
      member = Fake.fake_user!()

      group =
        Simulate.fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors"
        })

      assert {:ok, _} = Bonfire.Classify.Categories.join_group(member, group)

      {:ok, members_circle} = Bonfire.Boundaries.Scaffold.Groups.members_circle(group)

      Bonfire.Boundaries.Controlleds.remove_role(members_circle, group, :contribute,
        current_user: creator
      )

      assert {:error, _} = Bonfire.Classify.Categories.get(group.id, current_user: member),
             "the control: without the members circle's role the member cannot read, so the success below is the backfill's doing"

      run_member_access_backfill()

      assert {:ok, _} = Bonfire.Classify.Categories.get(group.id, current_user: member)

      run_member_access_backfill()

      assert {:ok, _} = Bonfire.Classify.Categories.get(group.id, current_user: member),
             "running it twice leaves the member's access as it was"
    end

    # The `local_community` preset used to pair `local:members` and `local:contributors` with the preview visibility; it now makes the group readable on this instance. The groups made from it earlier keep the old visibility until this backfill moves them, and a group that only happens to share two of the three dimensions is not the preset's.
    test "the local community backfill makes the preset's older groups readable, and leaves others as they were" do
      creator = Fake.fake_user!()
      stranger = Fake.fake_user!()

      older =
        Simulate.fake_group!(creator, %{
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors"
        })

      other =
        Simulate.fake_group!(creator, %{
          membership: "open",
          visibility: "nonfederated:preview",
          participation: "local:contributors"
        })

      for group <- [older, other] do
        assert {:error, _} = Bonfire.Classify.Categories.get(group.id, current_user: stranger),
               "the control: a local non-member only previews it before the backfill"

        assert {:error, _} = Bonfire.Classify.Categories.get(group.id, current_user: nil),
               "the control: a guest only previews it before the backfill"
      end

      run_local_community_backfill()

      assert {:ok, _} = Bonfire.Classify.Categories.get(older.id, current_user: stranger)
      assert {:ok, _} = Bonfire.Classify.Categories.get(older.id, current_user: nil)

      assert Presets.group_dimension_slugs(older)[:visibility] == "nonfederated"
      assert Presets.group_dimension_slugs(older)[:membership] == "local:members"
      assert Presets.group_dimension_slugs(older)[:participation] == "local:contributors"

      assert {:error, _} = Bonfire.Classify.Categories.get(other.id, current_user: stranger),
             "a group with other dimensions is unchanged"

      assert Presets.group_dimension_slugs(other)[:visibility] == "nonfederated:preview"

      run_local_community_backfill()

      assert Presets.group_dimension_slugs(older)[:visibility] == "nonfederated",
             "running it twice leaves the group as it was"
    end

    defp run_local_community_backfill do
      Bonfire.Classify.Boundaries.LocalCommunityVisibilityDataMigration.base_query()
      |> Repo.all()
      |> Bonfire.Classify.Boundaries.LocalCommunityVisibilityDataMigration.migrate()
    end

    defp run_member_access_backfill do
      Bonfire.Classify.Boundaries.GroupMemberAccessDataMigration.base_query()
      |> Repo.all()
      |> Bonfire.Classify.Boundaries.GroupMemberAccessDataMigration.migrate()
    end

    defp acl_ids_on(group) do
      Controlleds.list_acls_on_object(group)
      |> Enum.map(&(e(&1, :acl_id, nil) || e(&1, :acl, :id, nil)))
      |> Enum.reject(&is_nil/1)
    end
  end
end
