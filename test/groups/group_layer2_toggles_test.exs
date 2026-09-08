if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupLayer2TogglesTest do
    @moduledoc """
    Layer-2 toggles are overrides on a preset, each enacting one or more of the layer-3 dimensions ("discoverable", "anyone can post", "federate"). The two directions have to agree: `layer2_from_dims/1` reads a toggle's state out of the dimension slugs, `dims_from_layer2_overrides/2` writes a flipped toggle back into them. A toggle that reads but never writes is worse than a missing one, because it shows a state the group does not have and accepts a change that silently does nothing. The GraphQL API takes these overrides directly (`Bonfire.Classify.GraphQL.Resolver`), so it is reachable without any UI.

    Two of the layer-3 dimensions are laid out as the same scope × role grid: `visibility` and `default_content_visibility` each have a `:interact`, a `:discover` and an `:unlisted_read` slug in the `global`, `nonfederated` and `local` scopes. `discoverable` moves along the ROLE axis; `federate` moves along the SCOPE axis, in both dimensions at once, because federating a group whose posts still default to a non-federating boundary sends nothing.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Classify.Boundaries

    defp after_toggle(dims, overrides), do: Boundaries.dims_from_layer2_overrides(dims, overrides)

    defp visibility_after(slug, overrides),
      do: after_toggle(%{visibility: slug}, overrides)[:visibility]

    defp dcv_after(slug, overrides),
      do:
        after_toggle(%{default_content_visibility: slug}, overrides)[:default_content_visibility]

    describe "the federate toggle, on the visibility dimension" do
      test "turning it on moves the group to the federated slug of the same role" do
        assert visibility_after("nonfederated", %{federate: true}) == "global",
               "a group readable by everyone on this instance becomes readable by everyone, full stop"

        assert visibility_after("nonfederated:discoverable", %{federate: true}) == "discoverable",
               "federating a discoverable group must keep it discoverable, not promote it to fully readable"

        assert visibility_after("nonfederated:unlisted", %{federate: true}) == "unlisted"
      end

      test "turning it off brings the group back to the equivalent local-only slug" do
        assert visibility_after("global", %{federate: false}) == "nonfederated"
        assert visibility_after("discoverable", %{federate: false}) == "nonfederated:discoverable"
        assert visibility_after("unlisted", %{federate: false}) == "nonfederated:unlisted"
      end

      test "the toggle reads back the state it just wrote" do
        for slug <- ["nonfederated", "nonfederated:discoverable", "nonfederated:unlisted"] do
          federated = visibility_after(slug, %{federate: true})

          assert Boundaries.layer2_from_dims(%{visibility: federated})[:federate],
                 "#{slug} → #{federated} should read back as federating"

          refute Boundaries.layer2_from_dims(%{visibility: slug})[:federate]
        end
      end
    end

    # The dimension that decides the boundary of each POST, which is the half that actually reaches other instances: a group whose actor federates but whose posts default to `nonfederated` publishes an empty shell. Its federated slugs are spelled `public*` rather than `global*`, which `Presets.slug_scope/1` resolves to the same scope.
    describe "the federate toggle, on the default content visibility dimension" do
      test "turning it on moves posts to the federated boundary of the same role" do
        assert dcv_after("nonfederated", %{federate: true}) == "public",
               "federating the group has to federate what people post in it, or the group relays nothing"

        assert dcv_after("nonfederated:preview", %{federate: true}) == "public:preview"
        assert dcv_after("nonfederated:quiet", %{federate: true}) == "public:quiet"
      end

      test "turning it off brings posts back to the non-federating boundary" do
        assert dcv_after("public", %{federate: false}) == "nonfederated"
        assert dcv_after("public:preview", %{federate: false}) == "nonfederated:preview"
        assert dcv_after("public:quiet", %{federate: false}) == "nonfederated:quiet"
      end

      test "both dimensions move together in one override" do
        assert %{visibility: "global", default_content_visibility: "public"} =
                 after_toggle(
                   %{visibility: "nonfederated", default_content_visibility: "nonfederated"},
                   %{federate: true}
                 )
      end
    end

    describe "the federate toggle leaves alone what it has no counterpart for" do
      # There is no federated-vs-local counterpart of "members only", and taking the same-role slug in another scope would publish a private group.
      test "a members-only group is not published by flipping federate" do
        assert visibility_after("members:private", %{federate: true}) == "members:private"

        assert dcv_after("members:private", %{federate: true}) == "members:private",
               "a members-only default boundary must never be widened by a federation toggle"
      end

      test "a dimension that was not set stays unset" do
        assert after_toggle(%{visibility: "nonfederated"}, %{federate: true}) == %{
                 visibility: "global"
               }
      end

      # `dims_from_layer2_overrides/2` takes string keys from form params as well as atoms.
      test "it accepts a string key, as form params send it" do
        assert visibility_after("nonfederated", %{"federate" => true}) == "global"
      end
    end

    # Named for the axis it decides (member-list vs not) rather than for one of its values: `local:contributors` lets non-members post while being nothing like "anyone". Which population it means follows the group's own reach, so the toggle picks the contributors slug in the group's scope instead of a fixed one — otherwise turning it on in a federated group silently grants local-only posting.
    describe "the nonmembers_may_post toggle" do
      defp participation_after(visibility, participation, overrides) do
        after_toggle(%{visibility: visibility, participation: participation}, overrides)[
          :participation
        ]
      end

      test "picks the population matching the group's reach" do
        assert participation_after("global", "group_members", %{nonmembers_may_post: true}) ==
                 "anyone",
               "in a federated group, the people who are not members include remote ones"

        assert participation_after("nonfederated", "group_members", %{nonmembers_may_post: true}) ==
                 "local:contributors",
               "a group that federates nothing has only local users to open up to"

        assert participation_after("local", "group_members", %{nonmembers_may_post: true}) ==
                 "local:contributors"
      end

      test "turning it off restricts posting to members whatever the reach" do
        for visibility <- ["global", "nonfederated", "local"] do
          assert participation_after(visibility, "anyone", %{nonmembers_may_post: false}) ==
                   "group_members"
        end
      end

      test "the toggle reads back the state it just wrote" do
        for visibility <- ["global", "nonfederated", "local"] do
          opened = participation_after(visibility, "group_members", %{nonmembers_may_post: true})

          assert Boundaries.layer2_from_dims(%{participation: opened})[:nonmembers_may_post],
                 "#{visibility} → #{opened} should read back as open to non-members"

          refute Boundaries.layer2_from_dims(%{participation: "group_members"})[
                   :nonmembers_may_post
                 ]

          refute Boundaries.layer2_from_dims(%{participation: "moderators"})[
                   :nonmembers_may_post
                 ],
                 "moderators-only is the other member-list slug, and is not open to non-members either"
        end
      end

      test "it accepts a string key, as form params send it" do
        assert participation_after("global", "group_members", %{"nonmembers_may_post" => true}) ==
                 "anyone"
      end
    end

    # Renamed from `approval_required`, which did not say approval of WHAT — a moderated federated group reviews joins AND posts, and those are different toggles. Its "off" value had also drifted: the API path set `open` (federated, anyone anywhere joins) while the editor set `local:members`, for the very same switch.
    describe "the joins_need_approval toggle" do
      defp membership_after(visibility, membership, overrides) do
        after_toggle(%{visibility: visibility, membership: membership}, overrides)[:membership]
      end

      test "turning it on requires review whatever the group's reach" do
        for visibility <- ["global", "nonfederated", "local"] do
          assert membership_after(visibility, "open", %{joins_need_approval: true}) ==
                   "on_request"
        end
      end

      test "turning it off opens joining to the population matching the group's reach" do
        assert membership_after("global", "on_request", %{joins_need_approval: false}) == "open",
               "a federated group anyone may join is open to remote people, which is what `open` means"

        assert membership_after("nonfederated", "on_request", %{joins_need_approval: false}) ==
                 "local:members",
               "a group that federates nothing can only be joined by local users, so `open` would be a lie"

        assert membership_after("local", "on_request", %{joins_need_approval: false}) ==
                 "local:members"
      end

      test "the toggle reads back the state it just wrote" do
        for visibility <- ["global", "nonfederated", "local"] do
          opened = membership_after(visibility, "on_request", %{joins_need_approval: false})

          refute Boundaries.layer2_from_dims(%{membership: opened})[:joins_need_approval],
                 "#{visibility} → #{opened} should read back as needing no approval"

          assert Boundaries.layer2_from_dims(%{membership: "on_request"})[:joins_need_approval]
        end
      end
    end

    # Form params arrive as strings, so values are coerced with `Types.maybe_to_boolean/1` rather than plain truthiness — under which `"false"` is true.
    describe "toggle values that are not booleans" do
      test "string params are understood" do
        assert participation_after("global", "group_members", %{"nonmembers_may_post" => "true"}) ==
                 "anyone"

        assert participation_after("global", "anyone", %{"nonmembers_may_post" => "false"}) ==
                 "group_members",
               "plain truthiness would read the string \"false\" as on, and open the group"

        assert membership_after("global", "open", %{"joins_need_approval" => "true"}) ==
                 "on_request"
      end

      # Pins the behaviour rather than endorsing it: an unrecognised value is read as `false`, and the two toggles have OPPOSITE polarity, so `false` is restrictive for one and permissive for the other. Sending an unrecognised `joins_need_approval` therefore opens joining. Only a caller who explicitly includes the key is affected, since `dims_from_layer2_overrides/2` iterates the keys it is given.
      test "an unrecognised value is read as false, whichever way that falls" do
        assert participation_after("global", "anyone", %{nonmembers_may_post: nil}) ==
                 "group_members"

        assert membership_after("global", "on_request", %{joins_need_approval: nil}) == "open"
      end
    end

    # Guard: the two visibility toggles move along different axes of the same grid, so neither may drag the other along.
    describe "the toggles stay independent" do
      test "federating a group does not change whether it is discoverable" do
        for slug <- ["nonfederated", "nonfederated:discoverable", "nonfederated:unlisted"] do
          before = Boundaries.layer2_from_dims(%{visibility: slug})[:discoverable]
          federated = visibility_after(slug, %{federate: true})

          assert Boundaries.layer2_from_dims(%{visibility: federated})[:discoverable] == before,
                 "#{slug} → #{federated} changed discoverability as a side effect"
        end
      end

      test "making a group discoverable does not change whether it federates" do
        for slug <- ["nonfederated", "global"] do
          discoverable = visibility_after(slug, %{discoverable: true})

          assert Boundaries.layer2_from_dims(%{visibility: discoverable})[:federate] ==
                   Boundaries.layer2_from_dims(%{visibility: slug})[:federate],
                 "#{slug} → #{discoverable} changed federation as a side effect"
        end
      end
    end
  end
end
