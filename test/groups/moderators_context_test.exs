if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.ModeratorsContextTest do
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils

    alias Bonfire.Me.Fake
    alias Bonfire.Classify.Categories
    alias Bonfire.Boundaries

    setup do
      Process.put(:federating, false)
      :ok
    end

    test "add_moderator promotes a user (empowers :mediate, lists them)" do
      creator = Fake.fake_user!()
      user = Fake.fake_user!()
      group = fake_group!(creator)

      assert {:ok, %{role: "moderator"}} = Categories.add_moderator(creator, group, id(user))

      assert Boundaries.can?(user, :mediate, group)
      assert Categories.member_role(user, group) == "moderator"
      assert Enum.any?(Categories.moderators(group), &(id(&1) == id(user)))
    end

    test "remove_moderator demotes a user" do
      creator = Fake.fake_user!()
      user = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, _} = Categories.add_moderator(creator, group, id(user))
      assert Boundaries.can?(user, :mediate, group)

      assert {:ok, true} = Categories.remove_moderator(creator, group, id(user))

      refute Boundaries.can?(user, :mediate, group)
      refute Enum.any?(Categories.moderators(group), &(id(&1) == id(user)))
    end

    test "a non-moderator cannot add a moderator" do
      creator = Fake.fake_user!()
      rando = Fake.fake_user!()
      target = Fake.fake_user!()
      group = fake_group!(creator)

      assert {:error, _} = Categories.add_moderator(rando, group, id(target))
      refute Boundaries.can?(target, :mediate, group)
    end

    test "a promoted moderator can in turn promote others (:mediate gate)" do
      creator = Fake.fake_user!()
      mod = Fake.fake_user!()
      target = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, _} = Categories.add_moderator(creator, group, id(mod))
      assert {:ok, %{role: "moderator"}} = Categories.add_moderator(mod, group, id(target))
      assert Boundaries.can?(target, :mediate, group)
    end

    test "a moderator is allowed to manage the group (the gate used for creating topics)" do
      creator = Fake.fake_user!()
      mod = Fake.fake_user!()
      plain = Fake.fake_user!()
      group = fake_group!(creator)

      {:ok, _} = Categories.add_moderator(creator, group, id(mod))

      # `ensure_update_allowed/2` is the predicate gating topic creation + settings
      assert Bonfire.Classify.ensure_update_allowed(mod, group)
      refute Bonfire.Classify.ensure_update_allowed(plain, group)
    end

    test "the :moderate role is granted to the circle, so circle members inherit it automatically" do
      creator = Fake.fake_user!()
      first = Fake.fake_user!()
      later = Fake.fake_user!()
      group = fake_group!(creator)

      # promoting the first moderator empowers the moderators circle on the group
      {:ok, _} = Categories.add_moderator(creator, group, id(first))

      # a user added DIRECTLY to the circle (not via add_moderator) is now a moderator
      {:ok, circle} = Categories.moderators_circle(group)
      Bonfire.Boundaries.Circles.add_to_circles(later, circle)

      assert Boundaries.can?(later, :mediate, group),
             "expected a circle member to inherit :mediate from the circle grant"

      assert Enum.any?(Categories.moderators(group), &(id(&1) == id(later)))
    end
  end
end
