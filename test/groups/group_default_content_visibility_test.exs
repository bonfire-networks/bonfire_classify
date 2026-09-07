if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupDefaultContentVisibilityTest do
    @moduledoc """
    What boundary a group hands its composer when nobody picked one.

    `default_content_visibility` is what the group-page composer pre-fills `to_boundaries` with, so it decides the boundary of every post written in the group by someone who never opened the boundary picker. A group whose visibility is `global` is federated by definition, so its posts have to be federated too: anything narrower produces a post addressed to the group alone, with no `Public` in `to`, which the group's own instance then cannot show in a public feed.

    This matters twice, because the same derivation runs for groups nobody configured here at all: `Categories.create_remote/2` scaffolds a mirrored remote community from what its actor declares, and an actor that says nothing is treated as open, which cascades to `global`.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Classify.Boundaries

    describe "the default derived from a group's visibility" do
      test "a globally visible group defaults its posts to public" do
        assert Boundaries.default_content_visibility_for("global") == "public",
               "a group anyone anywhere can see is federated by definition, so a post in it that does not federate is addressed to nobody"

        assert Boundaries.default_content_visibility_for("global:discoverable") == "public"
      end

      test "a local group still defaults to local, and a members-only one to members" do
        assert Boundaries.default_content_visibility_for("local") == "local"
        assert Boundaries.default_content_visibility_for("local:discoverable") == "local"

        assert Boundaries.default_content_visibility_for("members:private") == "members:private",
               "widening the global case must not widen the restricted ones"
      end

      test "a group that federates nothing keeps its posts off the wire" do
        assert Boundaries.default_content_visibility_for("nonfederated:discoverable") ==
                 "nonfederated"
      end

      # The default is only a default: a group that states its own keeps it.
      test "an explicit default_content_visibility wins over the derived one" do
        assert {_slugs, _visibility, _participation, "members:private"} =
                 Boundaries.resolve_dims(%{
                   visibility: "global",
                   default_content_visibility: "members:private"
                 })
      end
    end

    # `Settings.get(scope: object)` reads the `:settings` assoc off the struct and never loads it, so an unloaded assoc is indistinguishable from an unset value: the group reads back as having no default, the composer gets `to_boundaries: []`, and the post lands on a custom boundary instead of the group's. Callers hand over whatever the page assigned, so the read has to load it itself.
    describe "reading it off a group the caller did not preload" do
      test "finds the stored value anyway" do
        creator = Bonfire.Me.Fake.fake_user!()

        group =
          fake_group!(creator, %{
            membership: "local:members",
            visibility: "nonfederated",
            participation: "anyone",
            default_content_visibility: "nonfederated"
          })

        # a bare Ecto fetch, because `Categories.get/2` preloads settings for you and would prove nothing here
        unloaded = repo().get(Bonfire.Classify.Category, id(group))

        refute Ecto.assoc_loaded?(unloaded.settings),
               "control: this test is meaningless if the fetch already preloaded settings"

        assert Boundaries.read_default_content_visibility(unloaded) == "nonfederated",
               "the group has a stored default, so reading it must not depend on the caller having preloaded it"
      end
    end

    # This is the dimension map `Categories.create_remote/2` builds for a community whose actor declares nothing: `remote_dims/1` reads no `openness` and no `manuallyApprovesFollowers`, treats the group as open, and cascades. A mirror is only ever posted into in order to federate the post BACK to the group, so a non-federating default here means every post written in a mirrored community is dropped before it leaves.
    test "a mirrored remote community scaffolds a federating default" do
      dims = Map.put(Boundaries.cascade_from_membership("open"), :membership, "open")

      assert {_slugs, "global", _participation, dcv} = Boundaries.resolve_dims(dims)

      assert dcv == "public",
             "posting into a mirrored community exists to send the post to that community, so its default cannot be one that never leaves this instance"
    end
  end
end
