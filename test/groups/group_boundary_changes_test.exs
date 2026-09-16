if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Classify.GroupBoundaryChangesTest do
    @moduledoc """
    One path for changing a group's boundaries, whoever asks.

    A caller expresses a change in up to three ways: a `preset` naming a whole set of dimensions, explicit `dims` overriding individual ones, and layer-2 `overrides`, the toggles that are read back out of the dimensions they enact. `Boundaries.resolve_changes/2` layers them in that order and `apply_changes/4` applies the result ONCE, so the group settings UI and the GraphQL API cannot produce different boundaries from the same request.

    Applying once also matters for correctness, not just for writes: a second pass would have to read the first one back through `group_dimension_slugs/1`, and detection is by ACL signature, so anything with no signature of its own would not survive the round trip.
    """
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils

    alias Bonfire.API.GraphQL.Schema
    alias Bonfire.Boundaries.Presets
    alias Bonfire.Classify.Boundaries

    import Bonfire.Classify.Simulate
    import Bonfire.Me.Fake

    @moduletag :graphql

    setup do
      Process.put(:federating, false)
      me = fake_user!(fake_account!())
      {:ok, me: me}
    end

    defp dims_of(group), do: Presets.group_dimension_slugs(group)

    describe "resolve_changes/2 layers the three kinds of change" do
      test "a preset alone gives that preset's dimensions" do
        assert {:ok, dims} = Boundaries.resolve_changes(%{preset: "private_club"})

        meta = Config.get([:group_presets, "private_club"], %{}, :bonfire_classify)
        assert dims[:membership] == meta.membership
        assert dims[:visibility] == meta.visibility
      end

      test "explicit dims override the preset they are sent with" do
        assert {:ok, dims} =
                 Boundaries.resolve_changes(%{
                   preset: "private_club",
                   dims: %{membership: "open"}
                 })

        assert dims[:membership] == "open",
               "the caller named a membership, so the preset's must not win"

        assert dims[:visibility] ==
                 Config.get([:group_presets, "private_club"], %{}, :bonfire_classify).visibility,
               "and the dimensions they did NOT name still come from the preset"
      end

      test "what a caller mentions nothing about keeps its current value" do
        assert {:ok, dims} =
                 Boundaries.resolve_changes(%{dims: %{membership: "open"}}, %{
                   membership: "invite_only",
                   visibility: "local",
                   participation: "anyone"
                 })

        assert dims[:membership] == "open"
        assert dims[:visibility] == "local"
        assert dims[:participation] == "anyone"
      end

      # The toggles are the last layer because they are a view OF the dimensions: `layer2_from_dims/1` reads one back out of the visibility's `role:`, so a request naming both a preset and a toggle means "that preset, then this toggle applied to it".
      #
      # `public_local_community` is visible at `role: :interact`, so switching the toggle ON has somewhere to move it to. A preset already at `role: :preview_discover` (like `private_club`) would make this pass without the toggle doing anything.
      test "a layer-2 toggle applies on top of the preset in the same request" do
        assert {:ok, base} = Boundaries.resolve_changes(%{preset: "public_local_community"})

        refute Boundaries.layer2_from_dims(base).discoverable,
               "control: the toggle must start OFF for turning it on to prove anything"

        assert {:ok, toggled} =
                 Boundaries.resolve_changes(%{
                   preset: "public_local_community",
                   overrides: %{discoverable: true}
                 })

        assert Boundaries.layer2_from_dims(toggled).discoverable == true
        refute toggled[:visibility] == base[:visibility]
      end

      test "and turning one off moves the visibility back" do
        assert {:ok, base} = Boundaries.resolve_changes(%{preset: "private_club"})

        assert Boundaries.layer2_from_dims(base).discoverable,
               "control: `private_club` is the preset that starts with this toggle ON"

        assert {:ok, toggled} =
                 Boundaries.resolve_changes(%{
                   preset: "private_club",
                   overrides: %{discoverable: false}
                 })

        refute Boundaries.layer2_from_dims(toggled).discoverable
        refute toggled[:visibility] == base[:visibility]
      end
    end

    describe "a slug the dimension does not offer" do
      # `boundaries_normalise_direct/1` reads anything it does not recognise as an ACL id, so an unoffered slug does not fail loudly, it silently becomes no boundary at all. The UI cannot send one because its form only offers what `slug_order` lists; this is the same guarantee for every other caller.
      test "is refused rather than applied" do
        assert {:error, _} =
                 Boundaries.resolve_changes(%{dims: %{visibility: "not_a_real_slug"}})
      end

      test "is refused even when it is a real slug from a DIFFERENT dimension" do
        assert "local:unlisted" in Presets.dimension_slug_order(:visibility),
               "control: this is a real slug, just not one of this dimension's"

        refute "local:unlisted" in Presets.dimension_slug_order(:default_content_visibility)

        assert {:error, _} =
                 Boundaries.resolve_changes(%{
                   dims: %{default_content_visibility: "local:unlisted"}
                 })
      end

      # A group whose posting is governed by a circle rather than a named slug puts that circle's id in the participation dimension, which `maybe_apply_participation_custom/3` grants directly. So participation is the one dimension where an unrecognised value is meaningful.
      test "but a circle id is still allowed for participation" do
        {:ok, circle} =
          Bonfire.Boundaries.Circles.create(fake_user!(), %{named: %{name: "editors"}})

        assert {:ok, dims} =
                 Boundaries.resolve_changes(%{dims: %{participation: id(circle)}})

        assert dims[:participation] == id(circle)
      end
    end

    describe "the same request through either caller" do
      test "lands the same stored dimensions", %{me: me} do
        via_context = fake_group!(me, %{membership: "open", visibility: "local"})
        via_api = fake_group!(me, %{membership: "open", visibility: "local"})

        changes = %{dims: %{membership: "on_request", visibility: "nonfederated"}}
        assert :ok = Boundaries.apply_changes(via_context, me, changes)

        {:ok, result} =
          Absinthe.run(
            ~S|mutation($id: ID!) {
              update_category(category_id: $id, category: {boundary: {dimensions: [
                {key: "membership", value: "on_request"},
                {key: "visibility", value: "nonfederated"}
              ]}}) { id }
            }|,
            Schema,
            variables: %{"id" => via_api.id},
            context: Schema.context(%{current_user: me})
          )

        refute result[:errors]

        assert dims_of(via_api) == dims_of(via_context),
               "the API and the settings UI share one context function, so the same intent cannot produce two different groups"

        assert dims_of(via_context).membership == "on_request",
               "control: assert the change actually happened, so two identically-unchanged groups cannot pass this"
      end

      # It used to be silent AND destructive: the parse ran inside a `rescue ArgumentError -> %{}`, so one unknown key discarded every other dimension in the request and the whole change became a no-op the client was never told about.
      test "an unknown dimension key is reported rather than swallowed", %{me: me} do
        group = fake_group!(me, %{membership: "open"})

        {:ok, result} =
          Absinthe.run(
            ~S|mutation($id: ID!) {
              update_category(category_id: $id, category: {boundary: {dimensions: [
                {key: "not_a_dimension", value: "whatever"},
                {key: "membership", value: "on_request"}
              ]}}) { id }
            }|,
            Schema,
            variables: %{"id" => group.id},
            context: Schema.context(%{current_user: me})
          )

        assert [%{message: message} | _] = result[:errors],
               "the client asked for something we cannot do, so the response has to say so"

        assert message =~ "not_a_dimension"

        assert dims_of(group).membership == "open",
               "and nothing is applied, so the group is not left half-changed"
      end
    end

    describe "the preset a group is on" do
      # Derived from the dimensions rather than stored, so it follows an edit. A stored copy only ever agreed with the group until the first boundary change.
      test "is not written to settings", %{me: me} do
        group = fake_group!(me, %{preset_slug: "private_club", membership: "invite_only"})

        assert is_nil(Bonfire.Common.Settings.get([:preset_slug], nil, scope: group)),
               "the preset is computable from the dimensions, so storing it only creates something that can disagree with them"
      end

      test "and its icon follows a boundary change", %{me: me} do
        group = fake_group!(me, %{preset_slug: "private_club", membership: "invite_only"})

        before = Presets.group_icon(group)

        assert :ok =
                 Boundaries.apply_changes(group, me, %{preset: "public_local_community"})

        assert Presets.group_icon(group) ==
                 Config.get([:group_presets, "public_local_community"], %{}, :bonfire_classify).icon

        refute Presets.group_icon(group) == before,
               "control: the two presets must have different icons for this to prove anything"
      end

      test "resolves for a whole list in one go", %{me: me} do
        groups = for _ <- 1..3, do: fake_group!(me, %{preset_slug: "private_club"})

        icons = Presets.group_icons(groups)

        for group <- groups do
          assert icons[id(group)] == Presets.group_icon(group)
        end
      end
    end
  end
end
