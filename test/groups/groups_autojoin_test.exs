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

      # `:after_signup_hooks` is a global instance setting kept in Application env (NOT rolled back
      # by the Ecto sandbox), so reset it around each test to avoid leftovers from other tests/runs.
      Bonfire.Common.Config.delete([Bonfire.Me.Users, :after_signup_hooks])
      on_exit(fn -> Bonfire.Common.Config.delete([Bonfire.Me.Users, :after_signup_hooks]) end)

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

      # a remote actor is created here whenever we fetch one (a profile looked at, someone mentioned or followed), which isn't anyone signing up: auto-joining it would make members of people who never joined
      test "a remote user created here is not auto-joined" do
        admin = Fake.fake_user!()
        {:ok, admin} = Bonfire.Me.Users.make_admin(admin)
        group = fake_group!(admin)

        Categories.set_auto_join_new_users(group, true, current_user: admin)

        # federating, which this module's setup turns off, as a remote actor is otherwise refused
        Process.put(:federating, true)
        Tesla.Mock.mock(fn env -> ActivityPub.Test.HttpRequestMock.request(env) end)
        {:ok, remote_user} = Bonfire.Federate.ActivityPub.Simulate.fake_remote_user()

        refute Bonfire.Social.is_local?(remote_user), "control: a remote user"
        refute Categories.member?(remote_user, group)
        refute Bonfire.Social.Graph.Follows.following?(remote_user, group)

        Categories.set_auto_join_new_users(group, false, current_user: admin)
      end
    end

    # browsers can't turn push on for someone, but once they do, a bell decides which notifications they get: this one hears the group's new posts
    describe "auto_bell_new_users" do
      test "toggling on registers it, toggling off removes it" do
        admin = Fake.fake_user!()
        {:ok, admin} = Bonfire.Me.Users.make_admin(admin)
        group = fake_group!(admin)

        refute Categories.auto_bell_new_users?(group)

        Categories.set_auto_bell_new_users(group, true, current_user: admin)
        assert Categories.auto_bell_new_users?(group)

        Categories.set_auto_bell_new_users(group, false, current_user: admin)
        refute Categories.auto_bell_new_users?(group)
      end

      test "a new user gets the group's bell on" do
        admin = Fake.fake_user!()
        {:ok, admin} = Bonfire.Me.Users.make_admin(admin)
        group = fake_group!(admin)

        # the positive control first: without the setting, a new user has no bell on the group
        refute Bonfire.Notify.Bells.enabled?(Fake.fake_user!(), group)

        Categories.set_auto_bell_new_users(group, true, current_user: admin)
        new_user = Fake.fake_user!()
        assert Bonfire.Notify.Bells.enabled?(new_user, group)
      end

      test "a remote user created here doesn't get the bell" do
        admin = Fake.fake_user!()
        {:ok, admin} = Bonfire.Me.Users.make_admin(admin)
        group = fake_group!(admin)

        Categories.set_auto_bell_new_users(group, true, current_user: admin)

        Process.put(:federating, true)
        Tesla.Mock.mock(fn env -> ActivityPub.Test.HttpRequestMock.request(env) end)
        {:ok, remote_user} = Bonfire.Federate.ActivityPub.Simulate.fake_remote_user()

        refute Bonfire.Social.is_local?(remote_user), "control: a remote user"
        refute Bonfire.Notify.Bells.enabled?(remote_user, group)
      end

      # both are stored in the same list of signup hooks, keyed by the group
      test "is independent of auto-join" do
        admin = Fake.fake_user!()
        {:ok, admin} = Bonfire.Me.Users.make_admin(admin)
        group = fake_group!(admin)

        Categories.set_auto_bell_new_users(group, true, current_user: admin)
        refute Categories.auto_join_new_users?(group)

        Categories.set_auto_join_new_users(group, true, current_user: admin)
        Categories.set_auto_join_new_users(group, false, current_user: admin)
        assert Categories.auto_bell_new_users?(group)
        refute Categories.auto_join_new_users?(group)

        # and a new user is belled without joining
        new_user = Fake.fake_user!()
        assert Bonfire.Notify.Bells.enabled?(new_user, group)
        refute Categories.member?(new_user, group)
      end
    end
  end
end
