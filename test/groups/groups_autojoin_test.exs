if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupAutoJoinTest do
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Me.Fake
    alias Bonfire.Classify.Categories

    setup do
      # TEMP: until we work on group federation
      Process.put(:federating, false)

      :ok
    end

    describe "auto_join_new_users" do
      test "toggling on adds the group to instance signup hooks, toggling off removes it" do
        admin = Fake.fake_user!()
        {:ok, admin} = Bonfire.Me.Users.make_admin(admin)
        group = fake_group!(admin)

        refute Categories.auto_join_new_users?(group)

        Categories.set_auto_join_new_users(group, true, current_user: admin)
        assert Categories.auto_join_new_users?(group)

        Categories.set_auto_join_new_users(group, false, current_user: admin)
        refute Categories.auto_join_new_users?(group)
      end

      test "a new user is auto-joined to groups registered in signup hooks" do
        admin = Fake.fake_user!()
        {:ok, admin} = Bonfire.Me.Users.make_admin(admin)
        group = fake_group!(admin)

        Categories.set_auto_join_new_users(group, true, current_user: admin)
        new_user = Fake.fake_user!()
        assert Categories.member?(new_user, group)

        Categories.set_auto_join_new_users(group, false, current_user: admin)
      end
    end
  end
end
