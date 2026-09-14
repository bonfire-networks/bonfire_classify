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

    # Rewinds a group to the shape it would have had before this change: the membership ACLs the `open` signature grew are removed, leaving only `everyone_may_see_read`.
    defp rewind_to_old_open_signature(group) do
      Controlleds.remove_acls(group, [:everyone_may_join, :everyone_may_request])
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
      Controlleds.add_acls(group, :no_follow)

      refute Bonfire.Boundaries.can?(stranger, :follow, group),
             "a negative grant wins, which is what leaves these groups unfollowable"

      run_backfill()

      refute Acls.get_id!(:no_follow) in acl_ids_on(group)

      assert Bonfire.Boundaries.can?(stranger, :follow, group),
             "reviewing who may join says nothing about who may subscribe to the feed"
    end

    test "the backfill leaves an already-current group untouched" do
      creator = Fake.fake_user!()
      group = Simulate.fake_group!(creator, %{membership: "open"})

      before = acl_ids_on(group) |> Enum.sort()

      run_backfill()

      assert acl_ids_on(group) |> Enum.sort() == before,
             "re-running has to be a no-op, since the backfill runs on every deploy"
    end

    defp acl_ids_on(group) do
      Controlleds.list_acls_on_object(group)
      |> Enum.map(&(e(&1, :acl_id, nil) || e(&1, :acl, :id, nil)))
      |> Enum.reject(&is_nil/1)
    end
  end
end
