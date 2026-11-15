defmodule Bonfire.Classify.GroupParticipationCustomCircleTest do
  @moduledoc """
  A group's participation may name a CIRCLE (its id) instead of one of the offered slugs: that circle is then who may post in the group, on top of what the visibility dimension gives. A circle that can't be granted is an error of the group's write, not something swallowed.
  """
  use Bonfire.Classify.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Classify.Simulate
  import Bonfire.Me.Fake, only: [fake_user!: 0]

  test "a group created with a circle as participation lets that circle's people post in it" do
    creator = fake_user!()
    writer = fake_user!()
    stranger = fake_user!()

    assert {:ok, circle} =
             Bonfire.Boundaries.Circles.create(creator, %{named: %{name: "writers"}})

    {:ok, _} =
      Bonfire.Boundaries.Circles.add_to_circles(writer, circle, skip_boundary_check: true)

    group =
      Simulate.fake_group!(creator, %{
        membership: "invite_only",
        visibility: "members:private",
        participation: circle.id
      })

    assert Bonfire.Boundaries.can?(writer, :create, group),
           "someone in the named circle may post"

    refute Bonfire.Boundaries.can?(stranger, :create, group),
           "control: someone outside it may not"
  end

  test "a participation circle that doesn't exist fails the group's write" do
    creator = fake_user!()
    group = Simulate.fake_group!(creator)

    assert {:error, _} =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "invite_only",
               visibility: "members:private",
               participation: Needle.UID.generate()
             })
  end
end
