defmodule Bonfire.Classify.ConvertGroupTopicFailureTest do
  @moduledoc """
  A conversion whose writes fail leaves the category the type it was, rather than a group with no rules. The real condition: the parent group's membership option has since been withdrawn from the options the instance offers, so the subgroup can't be given the parent's dimensions.
  """
  use Bonfire.Classify.DataCase, async: true
  use Bonfire.Common.Utils
  @moduletag :backend

  alias Bonfire.Classify.Categories
  alias Bonfire.Classify.Simulate
  import Bonfire.Me.Fake, only: [fake_user!: 0]

  test "a convert whose writes fail leaves a topic a topic" do
    creator = fake_user!()
    group = Simulate.fake_group!(creator, %{membership: "on_request", visibility: "global"})
    topic = Simulate.fake_category!(creator, group, %{type: :topic})

    dimensions = Bonfire.Common.Config.get(:preset_dimensions, %{}, :bonfire_boundaries)

    assert "on_request" in dimensions.membership.slug_order,
           "control: it is offered to begin with"

    # for this test's process only
    Process.put(
      [:bonfire_boundaries, :preset_dimensions],
      put_in(dimensions, [:membership, :slug_order], [])
    )

    assert {:error, _} = Categories.convert(topic, :group, current_user: creator)
    assert {:ok, %{type: :topic}} = Categories.get(id(topic), skip_boundary_check: true)

    Process.delete([:bonfire_boundaries, :preset_dimensions])

    assert {:ok, %{type: :group}} = Categories.convert(topic, :group, current_user: creator),
           "control: with the option offered again, it converts"
  end
end
