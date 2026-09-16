defmodule Bonfire.Classify.Boundaries.GroupAclSignaturesDataMigration do
  @moduledoc """
  Brings existing groups onto the current membership ACL signatures.

  Two things changed under them. First, `:request` left the read bundles and `:join` left `verbs_partake`, so six ACLs were versioned: each kept its name and took a new id, while the old id lives on under a `*_follow_join_request` / `*_request` name marked `deprecated`. Nothing edited the old rows, because preset ACLs are global fixtures that every object ever created against them still points at. Groups are re-pointed here; posts are deliberately left alone, where a legacy `:request` is wanted and a legacy `:join` is meaningless.

  Second, the membership signatures grew: `open` is now `[:everyone_may_see_read, :everyone_may_join, :everyone_may_request]` and `local:members` is `[:locals_may_join, :everyone_may_request]`. Matching is `MapSet.subset?`, so a group carrying only the old ACLs stops matching its own membership and falls back to `invite_only` (`Presets.membership_slug/1`). The missing grants are added here so each group keeps meaning what it always meant.

  Third, `on_request` stopped applying `no_follow`. Reviewing who may JOIN a group is not a reason to stop anyone FOLLOWING it, and the two are answered by different dimensions now. Existing groups keep that denial until it is taken off here, since `Controlled` rows are upserted and never pruned.

  Membership is re-derived from the OLD signatures, hardcoded below, because those are what the data was written against: asking the current config would answer `invite_only` for exactly the groups that need fixing.

  Safe to re-run: a group already holding the live ACL is skipped, and re-pointing is a no-op once no deprecated id remains.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Boundaries.Controlleds
  use DataMigration

  # Deprecated ACL => the live ACL that replaced it. Only these changed verbs; every other ACL kept its id.
  @versioned %{
    guests_may_see_read_request: :guests_may_see_read,
    guests_may_see_request: :guests_may_see,
    guests_may_read_request: :guests_may_read,
    locals_may_reply_follow_join_request: :locals_may_reply,
    remotes_may_reply_follow_join_request: :remotes_may_participate,
    locals_may_contribute_follow_join_request: :locals_may_contribute,
    remotes_may_contribute_follow_join_request: :remotes_may_contribute
  }

  # The membership signatures as they stood BEFORE `:everyone_may_join` and the paired `:everyone_may_request` were added. Largest matching set wins, mirroring `Presets.match_dimension/2`, which is what makes `on_request` (two ACLs) beat `open` (one) for a group carrying both.
  @old_membership_signatures [
    {"on_request", [:everyone_may_request, :no_follow]},
    {"local:members", [:locals_may_join]},
    {"open", [:everyone_may_see_read]}
  ]

  # What each membership slug must now carry, beyond what it already did.
  @membership_additions %{
    "open" => [:everyone_may_join, :everyone_may_request],
    "local:members" => [:everyone_may_request]
  }

  # What each membership slug must STOP carrying.
  #
  # An `on_request` group reviews who may JOIN it. It used to apply `no_follow`, which denied the `:follow` verb to local and remote users. So a group that only wanted to review new members was also stopping anyone from subscribing to its feed. Joining and following are answered by different dimensions now, and following is the visibility dimension's answer, so that denial has to come off.
  #
  # It has to come off here because `Controlled` rows are upserted and never pruned. The only other thing that removes them is someone editing the group's boundaries, and a long-established group is the least likely to have that happen.
  @membership_removals %{
    "on_request" => [:no_follow]
  }

  @doc "The deprecated-to-live ACL mapping this backfill applies. Exposed so a test can assert no `deprecated` ACL is left unmapped, which would strand every object still pointing at it."
  def versioned, do: @versioned

  @doc "The ACLs this backfill takes off a group without replacing them, keyed by membership slug. Exposed alongside `versioned/0` because a deprecated ACL is accounted for by appearing in either: one was replaced by a new id, the other is simply retired."
  def retired, do: @membership_removals

  @impl DataMigration
  def base_query do
    from(c in Bonfire.Classify.Category,
      where: c.type == :group,
      select: %{id: c.id}
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      async: true,
      batch_size: 500,
      throttle_ms: 1_000,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(results) do
    Enum.each(results, fn group ->
      acl_ids = acl_ids_on(group)

      # An `on_request` group is recognised by holding `[:everyone_may_request, :no_follow]`, and the removal step below takes `no_follow` away. So the slug is worked out once, from the ACLs as they stand before anything changes, and handed to both steps. Asking again afterwards would find no match.
      slug = old_membership_slug(acl_ids)

      repoint_versioned_acls(group, acl_ids)
      add_missing_membership_acls(group, slug, acl_ids)
      remove_retired_membership_acls(group, slug, acl_ids)
    end)
  end

  defp repoint_versioned_acls(group, acl_ids) do
    for {deprecated, live} <- @versioned,
        Acls.get_id!(deprecated) in acl_ids do
      # add before remove, so a group is never momentarily left without the boundary
      if Acls.get_id!(live) not in acl_ids, do: Controlleds.add_acls(group, live)
      Controlleds.remove_acls(group, [deprecated])
    end
  end

  defp add_missing_membership_acls(group, slug, acl_ids) do
    @membership_additions
    |> Map.get(slug, [])
    |> Enum.reject(&(Acls.get_id!(&1) in acl_ids))
    |> case do
      [] -> :skip
      missing -> Controlleds.add_acls(group, missing)
    end
  end

  defp remove_retired_membership_acls(group, slug, acl_ids) do
    @membership_removals
    |> Map.get(slug, [])
    |> Enum.filter(&(Acls.get_id!(&1) in acl_ids))
    |> case do
      [] -> :skip
      retired -> Controlleds.remove_acls(group, retired)
    end
  end

  defp acl_ids_on(group) do
    Controlleds.list_acls_on_object(group)
    |> Enum.map(&(e(&1, :acl_id, nil) || e(&1, :acl, :id, nil)))
    |> Enum.reject(&is_nil/1)
  end

  defp old_membership_slug(acl_ids) do
    present = MapSet.new(acl_ids)

    @old_membership_signatures
    |> Enum.filter(fn {_slug, acls} ->
      MapSet.subset?(MapSet.new(acls, &Acls.get_id!/1), present)
    end)
    |> Enum.max_by(fn {_slug, acls} -> length(acls) end, fn -> nil end)
    |> case do
      {slug, _} -> slug
      nil -> nil
    end
  end
end
